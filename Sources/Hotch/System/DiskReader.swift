import Foundation
import Darwin
import IOKit

/// Disk throughput from IOBlockStorageDriver "Statistics" (cached registry
/// entries, per-driver deltas so hot-plugged disks never produce a negative
/// rate), and boot-volume capacity.
final class DiskReader {
    private var drivers: [(id: UInt64, entry: io_registry_entry_t)] = []
    private var prev: [UInt64: (read: UInt64, write: UInt64)] = [:]
    private var prevNs: UInt64 = 0
    private var rates: (read: Double, write: Double) = (0, 0)
    private var needsDriverRefresh = false
    private(set) var volumeName = "Macintosh HD"
    private var namedVolume = false
    private var totalBytes: UInt64 = 0
    private var freeBytes: UInt64 = 0

    init() {
        refreshDrivers()
        refreshCapacityFast()
    }

    deinit {
        for d in drivers { IOObjectRelease(d.entry) }
    }

    func refreshDrivers() {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        var fresh: [(id: UInt64, entry: io_registry_entry_t)] = []
        var e = IOIteratorNext(it)
        while e != 0 {
            if DiskReader.isDiskImage(e) {
                // Disk images are files on another disk: their IO is already
                // counted there, so including them would double-count.
                IOObjectRelease(e)
            } else {
                var id: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(e, &id)
                fresh.append((id, e))
            }
            e = IOIteratorNext(it)
        }
        for d in drivers { IOObjectRelease(d.entry) }
        drivers = fresh
        needsDriverRefresh = false
    }

    private static func isDiskImage(_ driver: io_registry_entry_t) -> Bool {
        var device: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &device) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(device) }
        let protocolInfo = IORegistryEntryCreateCFProperty(device, "Protocol Characteristics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSDictionary
        return (protocolInfo?["Physical Interconnect" as NSString] as? String) == "Virtual Interface"
    }

    // Cached keys; NSDictionary lookups avoid bridging the whole dictionary.
    private let statisticsKey = "Statistics" as CFString
    private let readKey = "Bytes (Read)" as NSString
    private let writeKey = "Bytes (Write)" as NSString

    private func counters() -> [UInt64: (read: UInt64, write: UInt64)] {
        var out: [UInt64: (read: UInt64, write: UInt64)] = [:]
        out.reserveCapacity(drivers.count)
        for d in drivers {
            guard let st = IORegistryEntryCreateCFProperty(d.entry, statisticsKey, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSDictionary else {
                needsDriverRefresh = true
                continue
            }
            let r = (st[readKey] as? NSNumber)?.uint64Value ?? 0
            let w = (st[writeKey] as? NSNumber)?.uint64Value ?? 0
            out[d.id] = (r, w)
        }
        return out
    }

    func prime(now: UInt64) {
        prev = counters()
        prevNs = now
    }

    func read(now: UInt64) -> DiskReading {
        if needsDriverRefresh { refreshDrivers() }
        let cur = counters()
        if now > prevNs, !prev.isEmpty {
            var dr: UInt64 = 0, dw: UInt64 = 0
            for (id, c) in cur {
                guard let p = prev[id] else { continue }
                if c.read >= p.read { dr += c.read - p.read }
                if c.write >= p.write { dw += c.write - p.write }
            }
            let dt = Double(now - prevNs) / 1_000_000_000
            rates = (Double(dr) / dt, Double(dw) / dt)
        }
        prev = cur
        prevNs = now
        return DiskReading(volumeName: volumeName, totalBytes: totalBytes, freeBytes: freeBytes,
                           readBytesPerSecond: rates.read, writeBytesPerSecond: rates.write)
    }

    /// statfs only (~2 us): used until the first slow-tier refresh.
    private func refreshCapacityFast() {
        var s = statfs()
        guard statfs("/", &s) == 0 else { return }
        totalBytes = UInt64(s.f_blocks) * UInt64(s.f_bsize)
        if freeBytes == 0 { freeBytes = UInt64(s.f_bavail) * UInt64(s.f_bsize) }
    }

    /// Slow tier: Finder's "available" figure, purgeable space included (~5-7 ms).
    func refreshCapacity() {
        refreshCapacityFast()
        var url = URL(fileURLWithPath: "/")
        url.removeAllCachedResourceValues()
        var keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        if !namedVolume { keys.insert(.volumeLocalizedNameKey) }
        guard let v = try? url.resourceValues(forKeys: keys) else { return }
        if let important = v.volumeAvailableCapacityForImportantUsage, important > 0 {
            freeBytes = UInt64(important)
        }
        if let name = v.volumeLocalizedName, !name.isEmpty {
            volumeName = name
            namedVolume = true
        }
    }
}

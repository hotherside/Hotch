import Foundation
import IOKit

/// GPU utilisation from IOAccelerator "PerformanceStatistics" (public IOKit,
/// undocumented keys), ~45 us per read with cached registry entries.
/// Disables itself after repeated failures.
final class GPUReader {
    private var entries: [io_registry_entry_t] = []
    private let coreCount: Int?
    private let model: String?
    private var failures = 0
    private(set) var failed = false

    init?() {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var cores: Int?, name: String?
        var e = IOIteratorNext(it)
        while e != 0 {
            if IORegistryEntryCreateCFProperty(e, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() is [String: Any] {
                entries.append(e)
                if cores == nil {
                    cores = (IORegistryEntryCreateCFProperty(e, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
                }
                if name == nil {
                    name = IORegistryEntryCreateCFProperty(e, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                }
            } else {
                IOObjectRelease(e)
            }
            e = IOIteratorNext(it)
        }
        guard !entries.isEmpty else { return nil }
        coreCount = cores
        model = name
    }

    deinit {
        for e in entries { IOObjectRelease(e) }
    }

    private let statsKey = "PerformanceStatistics" as CFString
    private let utilKey = "Device Utilization %" as NSString
    private let utilKeyIntel = "GPU Activity(%)" as NSString
    private let memKey = "In use system memory" as NSString
    private let vramKey = "vramUsedBytes" as NSString

    func read() -> GPUReading? {
        guard !failed else { return nil }
        var best: (util: Double, mem: UInt64?)?
        for e in entries {
            guard let ps = IORegistryEntryCreateCFProperty(e, statsKey, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSDictionary else { continue }
            guard let util = (ps[utilKey] as? NSNumber ?? ps[utilKeyIntel] as? NSNumber)?.doubleValue else { continue }
            let mem = (ps[memKey] as? NSNumber ?? ps[vramKey] as? NSNumber)?.uint64Value
            if best == nil || util > best!.util { best = (util, mem) }
        }
        guard let b = best else {
            failures += 1
            if failures >= 5 { failed = true }
            return nil
        }
        failures = 0
        return GPUReading(utilization: min(100, max(0, b.util)), memoryUsedBytes: b.mem, coreCount: coreCount, model: model)
    }
}

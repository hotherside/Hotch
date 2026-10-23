import Foundation
import Darwin
import SystemConfiguration
import CoreWLAN
import notify

/// Primary-interface throughput from the 64-bit ifmib sysctl. NET_RT_IFLIST2 is
/// truncated for unentitled callers on macOS 27, so it is not used.
/// Wi-Fi link quality comes from CoreWLAN (RSSI and tx rate need no Location
/// permission; SSID would, so it is never read).
final class NetworkReader {
    private let store: SCDynamicStore?
    private(set) var primary: String?
    private var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, 0, IFDATA_GENERAL]
    private var prev: (rx: UInt64, tx: UInt64, ns: UInt64)?
    private var rates: (down: Double, up: Double) = (0, 0)
    private var totals: (rx: UInt64, tx: UInt64) = (0, 0)
    private var wifiNames: Set<String> = []
    private var localIPv4: String?
    private var rssi: Int?
    private var txRate: Double?
    /// configd posts this on any network configuration change; checking the
    /// token costs ~4 us, the SCDynamicStore read it replaces ~120 us cold.
    private var changeToken: Int32 = -1
    private var lastPrimaryCheckNs: UInt64 = 0

    init() {
        if notify_register_check("com.apple.system.config.network_change", &changeToken) != UInt32(NOTIFY_STATUS_OK) { changeToken = -1 }
        store = SCDynamicStoreCreate(nil, "Hotch.SystemMonitor" as CFString, nil, nil)
        wifiNames = Set(CWWiFiClient.shared().interfaceNames() ?? [])
        _ = refreshPrimary()
        localIPv4 = primary.flatMap(NetworkReader.ipv4(of:))
    }

    private var isWiFi: Bool { primary.map { wifiNames.contains($0) } ?? false }

    /// Re-reads the primary interface from SCDynamicStore (~13 us warm, ~120 us
    /// from a cold wake, hence the notify gate). Returns true on change.
    @discardableResult
    func refreshPrimary() -> Bool {
        var name: String?
        if let store {
            for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
                if let g = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                   let p = g["PrimaryInterface"] as? String, !p.isEmpty {
                    name = p
                    break
                }
            }
        }
        guard name != primary || (name != nil && mib[4] == 0) else { return false }
        primary = name
        mib[4] = name.map { Int32(bitPattern: if_nametoindex($0)) } ?? 0
        prev = nil
        rates = (0, 0)
        return true
    }

    private func counters() -> (rx: UInt64, tx: UInt64)? {
        guard mib[4] != 0 else { return nil }
        var data = ifmibdata()
        var len = MemoryLayout<ifmibdata>.size
        guard sysctl(&mib, 6, &data, &len, nil, 0) == 0 else { return nil }
        return (data.ifmd_data.ifi_ibytes, data.ifmd_data.ifi_obytes)
    }

    func prime(now: UInt64) {
        if let c = counters() { prev = (c.rx, c.tx, now); totals = c }
    }

    /// Local IPv4 and Wi-Fi link (CoreWLAN costs ~3 ms wall, ~80 us CPU).
    func refreshSlow() {
        if let names = CWWiFiClient.shared().interfaceNames() { wifiNames = Set(names) }
        localIPv4 = primary.flatMap(NetworkReader.ipv4(of:))
        refreshWiFiLink()
    }

    func refreshWiFiLink() {
        guard let p = primary, isWiFi, let iface = CWWiFiClient.shared().interface(withName: p) else {
            rssi = nil; txRate = nil
            return
        }
        let r = iface.rssiValue()
        let t = iface.transmitRate()
        rssi = r != 0 ? r : nil
        txRate = t > 0 ? t : nil
    }

    deinit {
        if changeToken != -1 { notify_cancel(changeToken) }
    }

    /// Re-reads the primary interface when configd signalled a change, or every 30 s as a safety net.
    private func primaryMayHaveChanged(now: UInt64) -> Bool {
        var changed: Int32 = 1
        if changeToken != -1 { notify_check(changeToken, &changed) }
        if changed != 0 || now &- lastPrimaryCheckNs > 30_000_000_000 {
            lastPrimaryCheckNs = now
            return true
        }
        return false
    }

    func read(now: UInt64, refreshWiFi: Bool) -> NetworkReading {
        if primaryMayHaveChanged(now: now), refreshPrimary() {
            localIPv4 = primary.flatMap(NetworkReader.ipv4(of:))
            refreshWiFiLink()
        } else if refreshWiFi {
            refreshWiFiLink()
        }
        if let c = counters() {
            if let p = prev, now > p.ns, c.rx >= p.rx, c.tx >= p.tx {
                let dt = Double(now - p.ns) / 1_000_000_000
                rates = (Double(c.rx - p.rx) / dt, Double(c.tx - p.tx) / dt)
            } else if prev != nil {
                rates = (0, 0) // counter reset on the interface; one quiet tick
            }
            prev = (c.rx, c.tx, now)
            totals = c
        } else {
            rates = (0, 0)
        }
        return NetworkReading(downBytesPerSecond: rates.down, upBytesPerSecond: rates.up,
                              primaryInterface: primary, isWiFi: isWiFi, localIPv4: localIPv4,
                              wifiRSSI: isWiFi ? rssi : nil, wifiTxRateMbps: isWiFi ? txRate : nil,
                              totalDownBytes: totals.rx, totalUpBytes: totals.tx)
    }

    private static func ipv4(of interface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var cursor = head
        while let a = cursor {
            defer { cursor = a.pointee.ifa_next }
            guard let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  String(cString: a.pointee.ifa_name) == interface else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}

import Foundation
import Darwin
import IOKit

/// Utilisation from mach tick deltas, plus topology, load average and uptime.
/// Totals come from host_statistics (no out-of-line buffer, ~12 us from a cold
/// wake); per-core shares come from host_processor_info (~70 us cold), read
/// every tick in the panel tier and every 5 s in the menuBar tier, where only
/// the total is shown. Confined to the sampler queue.
final class CPUReader {
    let performanceCount: Int
    let efficiencyCount: Int
    let isEfficiency: [Bool]
    private let bootTime: TimeInterval
    private var prev: [UInt32] = [] // user, system, idle, nice per core
    private var cores = 0
    private var prevTotal: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var perCore: [Double] = []
    private var loadMib: [Int32] = [CTL_VM, VM_LOADAVG]

    init() {
        let ncpu = max(1, SysCtl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount)
        var p = ncpu, e = 0
        if (SysCtl.int("hw.nperflevels") ?? 1) >= 2 {
            // perflevel0 is the fastest level. Check names in case that ever changes.
            let n0 = SysCtl.string("hw.perflevel0.name") ?? "Performance"
            let c0 = SysCtl.int("hw.perflevel0.logicalcpu") ?? 0
            let c1 = SysCtl.int("hw.perflevel1.logicalcpu") ?? 0
            if n0.hasPrefix("Eff") { p = c1; e = c0 } else { p = c0; e = c1 }
            if p + e != ncpu { p = max(0, ncpu - e) }
        }
        performanceCount = p
        efficiencyCount = e
        isEfficiency = CPUReader.coreTypes(count: ncpu, efficiencyCount: e)
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 {
            bootTime = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
        } else {
            bootTime = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        }
    }

    /// Maps logical CPU ids to E/P using IODeviceTree cpus/cpuN "cluster-type".
    /// Falls back to "the first N are efficiency cores" (true on M1 through M4).
    private static func coreTypes(count: Int, efficiencyCount: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: count)
        guard efficiencyCount > 0 else { return out }
        var mapped = 0
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        if cpus != 0 {
            var it: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &it) == KERN_SUCCESS {
                var e = IOIteratorNext(it)
                while e != 0 {
                    if let ct = IORegistryEntryCreateCFProperty(e, "cluster-type" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data,
                       let lid = IORegistryEntryCreateCFProperty(e, "logical-cpu-id" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber,
                       let first = ct.first, lid.intValue >= 0, lid.intValue < count {
                        out[lid.intValue] = first == UInt8(ascii: "E")
                        mapped += 1
                    }
                    IOObjectRelease(e)
                    e = IOIteratorNext(it)
                }
                IOObjectRelease(it)
            }
            IOObjectRelease(cpus)
        }
        if mapped != count || out.filter({ $0 }).count != efficiencyCount {
            for i in 0..<count { out[i] = i < efficiencyCount }
        }
        return out
    }

    private func readTicks() -> [UInt32]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let n = Int(count)
        var out = [UInt32](repeating: 0, count: n * 4)
        let stride = Int(CPU_STATE_MAX)
        for i in 0..<n {
            let b = stride * i
            out[i * 4 + 0] = UInt32(bitPattern: info[b + Int(CPU_STATE_USER)])
            out[i * 4 + 1] = UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)])
            out[i * 4 + 2] = UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)])
            out[i * 4 + 3] = UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)])
        }
        return out
    }

    private func readTotal() -> (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks // (user, system, idle, nice)
        return (t.0, t.1, t.2, t.3)
    }

    private func updatePerCore() {
        guard let cur = readTicks() else { return }
        let n = cur.count / 4
        if n == cores, prev.count == cur.count {
            var out = [Double](repeating: 0, count: n)
            for i in 0..<n {
                let busy = Double(cur[i * 4] &- prev[i * 4]) + Double(cur[i * 4 + 1] &- prev[i * 4 + 1]) + Double(cur[i * 4 + 3] &- prev[i * 4 + 3])
                let t = busy + Double(cur[i * 4 + 2] &- prev[i * 4 + 2])
                out[i] = t > 0 ? busy / t * 100 : 0
            }
            perCore = out
        }
        prev = cur
        cores = n
    }

    func prime() {
        prevTotal = readTotal()
        if let t = readTicks() { prev = t; cores = t.count / 4 }
    }

    /// `perCore`: refresh the per-core shares this tick (always done when none exist yet).
    func read(perCore refreshPerCore: Bool) -> CPUReading {
        var user = 0.0, system = 0.0, total = 0.0
        if let cur = readTotal() {
            if let p = prevTotal {
                let u = Double(cur.user &- p.user) + Double(cur.nice &- p.nice)
                let s = Double(cur.system &- p.system)
                let t = u + s + Double(cur.idle &- p.idle)
                if t > 0 { user = u / t * 100; system = s / t * 100; total = user + system }
            }
            prevTotal = cur
        }
        if refreshPerCore || perCore.isEmpty { updatePerCore() }
        var la = loadavg()
        var size = MemoryLayout<loadavg>.size
        var load = (0.0, 0.0, 0.0)
        if sysctl(&loadMib, 2, &la, &size, nil, 0) == 0, la.fscale > 0 {
            let f = Double(la.fscale)
            load = (Double(la.ldavg.0) / f, Double(la.ldavg.1) / f, Double(la.ldavg.2) / f)
        }
        var flags = isEfficiency
        if flags.count != perCore.count { flags = [Bool](repeating: false, count: perCore.count) }
        return CPUReading(total: min(100, total), user: user, system: system, perCore: perCore,
                          performanceCoreCount: performanceCount, efficiencyCoreCount: efficiencyCount,
                          isEfficiencyCore: flags, loadAverage1: load.0, loadAverage5: load.1, loadAverage15: load.2,
                          uptime: max(0, Date().timeIntervalSince1970 - bootTime), frequencyMHz: nil)
    }
}

/// Apple Silicon cluster clocks from IOReport "CPU Complex Performance States"
/// residencies, mapped onto the pmgr DVFS tables. Private API, loaded with dlopen.
/// Costs ~3-4 ms of CPU per sample, so the sampler calls it every 5 s and only
/// while a CPU detail view is visible. Returns nil (disables itself) on any failure.
final class CPUFrequencyReader {
    private typealias FCopyChannels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias FCreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> Unmanaged<CFTypeRef>?
    private typealias FCreateSamples = @convention(c) (CFTypeRef, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias FCreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias FGetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias FStateCount = @convention(c) (CFDictionary) -> Int32
    private typealias FStateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias FStateResidency = @convention(c) (CFDictionary, Int32) -> Int64

    private let createSamples: FCreateSamples
    private let createDelta: FCreateDelta
    private let channelName: FGetString
    private let stateCount: FStateCount
    private let stateName: FStateName
    private let stateResidency: FStateResidency
    private let subscription: CFTypeRef
    private let subscribed: CFMutableDictionary
    private let eTable: [Double]
    private let pTable: [Double]
    private var prev: CFDictionary?
    private(set) var failed = false
    private var failures = 0

    init?() {
        #if arch(arm64)
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        guard let copyChannels = sym("IOReportCopyChannelsInGroup", FCopyChannels.self),
              let createSubscription = sym("IOReportCreateSubscription", FCreateSubscription.self),
              let createSamples = sym("IOReportCreateSamples", FCreateSamples.self),
              let createDelta = sym("IOReportCreateSamplesDelta", FCreateDelta.self),
              let channelName = sym("IOReportChannelGetChannelName", FGetString.self),
              let stateCount = sym("IOReportStateGetCount", FStateCount.self),
              let stateName = sym("IOReportStateGetNameForIndex", FStateName.self),
              let stateResidency = sym("IOReportStateGetResidency", FStateResidency.self)
        else { return nil }

        let e = CPUFrequencyReader.pmgrTable("voltage-states1-sram")
        let p = CPUFrequencyReader.pmgrTable("voltage-states5-sram")
        guard !e.isEmpty, !p.isEmpty else { return nil }

        guard let channels = copyChannels("CPU Stats" as CFString, "CPU Complex Performance States" as CFString, 0, 0, 0)?.takeRetainedValue(),
              let all = (channels as NSDictionary)["IOReportChannels"] as? [CFDictionary],
              let mutable = (channels as NSDictionary).mutableCopy() as? NSMutableDictionary
        else { return nil }
        // Keep only the cluster channels (ECPU, PCPU, PCPU1, DIE_n_PCPU...). Filtering
        // before subscribing is what keeps the sample cheap.
        let keep = all.filter { CPUFrequencyReader.clusterKind(channelName($0)?.takeUnretainedValue() as String? ?? "") != nil }
        guard !keep.isEmpty else { return nil }
        mutable["IOReportChannels"] = NSMutableArray(array: keep)

        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = createSubscription(nil, mutable as CFMutableDictionary, &subbed, 0, nil)?.takeRetainedValue(),
              let subbedDict = subbed?.takeRetainedValue() else { return nil }

        self.createSamples = createSamples
        self.createDelta = createDelta
        self.channelName = channelName
        self.stateCount = stateCount
        self.stateName = stateName
        self.stateResidency = stateResidency
        self.subscription = sub
        self.subscribed = subbedDict
        self.eTable = e
        self.pTable = p
        #else
        return nil
        #endif
    }

    /// "E" or "P" for a cluster channel name, nil for anything else (ECPM, *_IDLE).
    private static func clusterKind(_ name: String) -> Character? {
        let base = name.split(separator: "_").last.map(String.init) ?? name
        for (prefix, kind) in [("ECPU", Character("E")), ("PCPU", Character("P"))] where base.hasPrefix(prefix) {
            let rest = base.dropFirst(prefix.count)
            if rest.allSatisfy({ $0.isNumber }) { return kind }
        }
        return nil
    }

    /// DVFS frequency table from the pmgr node, in MHz. M1 to M3 store Hz, M4 stores kHz.
    private static func pmgrTable(_ key: String) -> [Double] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var raw: [UInt32] = []
        var e = IOIteratorNext(it)
        while e != 0 {
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(e, &name)
            if raw.isEmpty, String(cString: name) == "pmgr",
               let d = IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data {
                raw = stride(from: 0, to: d.count - 7, by: 8).map { o in
                    d.subdata(in: o..<(o + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                }
            }
            IOObjectRelease(e)
            e = IOIteratorNext(it)
        }
        guard let maxValue = raw.max(), maxValue > 0 else { return [] }
        let divisor: Double = maxValue > 100_000_000 ? 1_000_000 : (maxValue > 100_000 ? 1_000 : 1)
        return raw.map { Double($0) / divisor }
    }

    func prime() {
        guard !failed else { return }
        prev = createSamples(subscription, subscribed, nil)?.takeRetainedValue()
    }

    func reset() { prev = nil }

    /// Average active clock per cluster type since the previous call.
    func sample() -> (e: Double?, p: Double?)? {
        guard !failed else { return nil }
        guard let cur = createSamples(subscription, subscribed, nil)?.takeRetainedValue() else {
            failures += 1
            if failures >= 3 { failed = true }
            return nil
        }
        defer { prev = cur }
        guard let p = prev, let delta = createDelta(p, cur, nil)?.takeRetainedValue(),
              let channels = (delta as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return nil }
        failures = 0
        var eW = 0.0, eR = 0.0, pW = 0.0, pR = 0.0
        for ch in channels {
            guard let kind = CPUFrequencyReader.clusterKind(channelName(ch)?.takeUnretainedValue() as String? ?? "") else { continue }
            let table = kind == "E" ? eTable : pTable
            let n = Int(stateCount(ch))
            var j = -1 // index into the frequency table once past IDLE/DOWN/OFF
            var weighted = 0.0, active = 0.0
            for i in 0..<n {
                let name = stateName(ch, Int32(i))?.takeUnretainedValue() as String? ?? ""
                if j < 0 && (name == "IDLE" || name == "DOWN" || name == "OFF") { continue }
                j += 1
                guard j < table.count else { break }
                let r = Double(stateResidency(ch, Int32(i)))
                weighted += r * table[j]
                active += r
            }
            if kind == "E" { eW += weighted; eR += active } else { pW += weighted; pR += active }
        }
        return (eR > 0 ? eW / eR : nil, pR > 0 ? pW / pR : nil)
    }
}

import Foundation
import Darwin

// MARK: - Small helpers

enum SysClock {
    /// Monotonic nanoseconds that keep counting through sleep, so a rate taken
    /// across a sleep is averaged over the real elapsed time.
    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }
}

enum SysCtl {
    static func int(_ name: String) -> Int? {
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        if size == MemoryLayout<Int32>.size {
            return Int(withUnsafeBytes(of: v) { $0.load(as: Int32.self) })
        }
        return Int(v)
    }

    static func int32(_ name: String) -> Int32? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return v
    }

    static func uint64(_ name: String) -> UInt64? {
        var v: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return v
    }

    /// A sysctl name resolved to its MIB once, then read by number.
    struct Mib {
        private var mib: [Int32]
        private let name: String

        init(_ name: String) {
            self.name = name
            var buf = [Int32](repeating: 0, count: Int(CTL_MAXNAME))
            var len = buf.count
            mib = sysctlnametomib(name, &buf, &len) == 0 ? Array(buf.prefix(len)) : []
        }

        /// For plain C structs and integers only.
        mutating func read<T>(_ value: inout T) -> Bool {
            let name = self.name
            var mib = self.mib
            return withUnsafeMutableBytes(of: &value) { buf -> Bool in
                var size = buf.count
                if mib.isEmpty { return sysctlbyname(name, buf.baseAddress, &size, nil, 0) == 0 }
                return sysctl(&mib, u_int(mib.count), buf.baseAddress, &size, nil, 0) == 0
            }
        }
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}

// MARK: - Sampler

/// What the sampler should collect. Built by SystemMonitor from client demands.
struct SystemSamplerConfig: Equatable, Sendable {
    /// Effective demand (for the snapshot's `demand` field).
    var demand: SystemDemand = .idle
    /// 0 idle (timer stopped), 1 menuBar, 2 panel (detail views count as panel).
    var level = 0
    /// A `.detail(.cpu)` client is present: IOReport cluster clocks every 5 s.
    var cpuDetail = false
    /// A `.detail(.network)` client is present: Wi-Fi link every 5 s.
    var networkDetail = false
    /// SMC temperatures, fans, power rails and IOReport.
    var advanced = true
}

struct SystemSamplerOutput: Sendable {
    var snapshot: SystemSnapshot
    /// Present on ticks where the process ranking was refreshed (every 2 s, panel tier).
    var processes: ProcessRanking?
    var stats: SystemSamplerStats
}

/// Sampler-thread CPU time spent building snapshots, for diagnostics.
struct SystemSamplerStats: Sendable {
    var ticks: UInt64 = 0
    var totalCPUNs: UInt64 = 0
    var maxCPUNs: UInt64 = 0
    var lastCPUNs: UInt64 = 0
}

/// One serial utility-QoS queue owns every reader and all sampling state.
/// A single DispatchSourceTimer ticks at 1 Hz with 10% leeway while the demand
/// is above idle; idle cancels it. Each tick builds one immutable snapshot inside
/// an autorelease pool and hands it to `output` (which hops to the main actor).
///
/// Tiers:
/// - menuBar: CPU total, memory, network, power basics, thermal state (1 Hz);
///   per-core CPU and disk IO as 5 s averages (every 5th tick)
/// - panel:   + per-core CPU, disk IO, GPU, SMC temps/fans/power rails, battery
///   watts (1 Hz), processes (every 2 s)
/// - detail(.cpu): + IOReport cluster clocks (every 5 s)
/// - slow tier: at start, on panel open if the last run is over 30 s old, then
///   every 60 s while panel: disk capacity, battery health and cycles, adapter
///   rating, Wi-Fi link, local IP, fan limits, disk driver list.
final class SystemSampler: @unchecked Sendable {
    typealias OutputHandler = @Sendable (SystemSamplerOutput) -> Void

    private let queue = DispatchQueue(label: "Hotch.SystemSampler", qos: .utility)
    private var output: OutputHandler?
    private var config = SystemSamplerConfig()
    private var timer: DispatchSourceTimer?
    private var ticks: UInt64 = 0
    private var lastTickNs: UInt64 = 0

    // Readers, created lazily on the queue.
    private lazy var cpu = CPUReader()
    private lazy var memory = MemoryReader()
    private lazy var network = NetworkReader()
    private lazy var disk = DiskReader()
    private lazy var power = PowerReader()
    private lazy var processes = ProcessReader()
    private var gpu: GPUReader?
    private var gpuTried = false
    private var sensors: SensorsReader?
    private var sensorsTried = false
    private var frequency: CPUFrequencyReader?
    private var frequencyTried = false

    private var slowDueNs: UInt64 = .max
    private var lastSlowNs: UInt64 = 0
    private var processDueNs: UInt64 = .max
    private var frequencyDueNs: UInt64 = .max
    private var wifiDueNs: UInt64 = .max
    private var lastFrequency: (e: Double?, p: Double?)?
    private var lastDisk: DiskReading?

    private static let second: UInt64 = 1_000_000_000
    /// Process ranking cadence in the panel tier (spec: 2-3 s).
    static let processInterval: UInt64 = 2 * second

    init() {}

    func setOutputHandler(_ handler: @escaping OutputHandler) {
        queue.async { self.output = handler }
    }

    func update(_ new: SystemSamplerConfig) {
        queue.async { self.apply(new) }
    }

    // MARK: Configuration

    private func apply(_ new: SystemSamplerConfig) {
        let old = config
        config = new
        guard new.level > 0 else {
            stopTimer()
            processes.reset()
            frequency?.reset()
            lastFrequency = nil
            frequencyDueNs = .max
            processDueNs = .max
            wifiDueNs = .max
            return
        }
        let now = SysClock.now()
        let wantsFrequency = new.cpuDetail && new.advanced
        let hadFrequency = old.cpuDetail && old.advanced && timer != nil

        if timer == nil {
            cpu.prime()
            network.prime(now: now)
            disk.prime(now: now)
            lastDisk = nil
            // First start runs the slow tier on the first tick; restarts reuse a
            // recent run (panel only) the same way opening the panel does.
            slowDueNs = (lastSlowNs == 0 || now &- lastSlowNs > 30 * SystemSampler.second) ? now : lastSlowNs + 60 * SystemSampler.second
            if new.level >= 2 { primePanel(now: now) }
            if wantsFrequency { primeFrequency(now: now) }
            wifiDueNs = new.networkDetail ? now : .max
            startTimer(after: 0.5)
            return
        }

        var early = false
        if new.level >= 2 && old.level < 2 {
            primePanel(now: now)
            slowDueNs = now &- lastSlowNs > 30 * SystemSampler.second ? now : lastSlowNs + 60 * SystemSampler.second
            early = true
        } else if new.level < 2 && old.level >= 2 {
            processes.reset()
            processDueNs = .max
        }
        if new.advanced && !old.advanced && new.level >= 2 { early = true }
        if wantsFrequency && !hadFrequency {
            primeFrequency(now: now)
        } else if !wantsFrequency {
            frequency?.reset()
            lastFrequency = nil
            frequencyDueNs = .max
        }
        if new.networkDetail && !old.networkDetail {
            wifiDueNs = now
            early = true
        } else if !new.networkDetail {
            wifiDueNs = .max
        }
        // Panel just opened: fire soon (but at least 0.3 s after the previous
        // tick so rates stay meaningful) instead of waiting up to a second.
        if early { reschedule(minimumGap: 0.3) }
    }

    private func primePanel(now: UInt64) {
        processes.prime(now: now)
        processDueNs = now + SystemSampler.second * 9 / 10
    }

    private func primeFrequency(now: UInt64) {
        if !frequencyTried {
            frequencyTried = true
            frequency = CPUFrequencyReader()
        }
        frequency?.prime()
        frequencyDueNs = now + SystemSampler.second / 4
    }

    private func startTimer(after delay: Double) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + delay, repeating: 1.0, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func reschedule(minimumGap: Double) {
        guard let timer else { return }
        let since = Double(SysClock.now() &- lastTickNs) / 1e9
        let delay = max(0.02, minimumGap - since)
        timer.schedule(deadline: .now() + delay, repeating: 1.0, leeway: .milliseconds(100))
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    // MARK: Tick

    private var stats = SystemSamplerStats()

    private func tick() {
        autoreleasepool {
            let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            guard var out = sample() else { return }
            let cost = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- c0
            stats.ticks += 1
            stats.totalCPUNs &+= cost
            stats.lastCPUNs = cost
            stats.maxCPUNs = max(stats.maxCPUNs, cost)
            out.stats = stats
            output?(out)
        }
    }

    private func sample() -> SystemSamplerOutput? {
        let cfg = config
        guard cfg.level > 0 else { return nil }
        let now = SysClock.now()
        ticks += 1
        lastTickNs = now
        let panel = cfg.level >= 2
        let second = SystemSampler.second

        // Lazily create the panel-only readers.
        if panel && !gpuTried { gpuTried = true; gpu = GPUReader() }
        if panel && cfg.advanced && !sensorsTried { sensorsTried = true; sensors = SensorsReader() }

        if now >= slowDueNs && (panel || lastSlowNs == 0) {
            disk.refreshCapacity()
            disk.refreshDrivers()
            power.refreshSlow()
            network.refreshSlow()
            if cfg.advanced { sensors?.refreshFanLimits() }
            lastDisk = nil
            lastSlowNs = now
            slowDueNs = panel ? now + 60 * second : .max
        }

        // Per-core shares and disk IO every tick in the panel tier, every 5 s in
        // the menuBar tier (the menu bar shows totals only). Values are always
        // real averages over their window, never placeholders.
        let fullRate = panel || ticks % 5 == 1
        var cpuReading = cpu.read(perCore: fullRate)
        if cfg.cpuDetail && cfg.advanced, let f = frequency {
            if now + second / 10 >= frequencyDueNs {
                if let v = f.sample() { lastFrequency = v }
                frequencyDueNs = now + 5 * second
            }
            cpuReading.frequencyMHz = f.failed ? nil : lastFrequency
        }

        let refreshWiFi = cfg.networkDetail && now + second / 10 >= wifiDueNs
        if refreshWiFi { wifiDueNs = now + 5 * second }
        let networkReading = network.read(now: now, refreshWiFi: refreshWiFi)

        let sensorValues: SensorsReader.Values? = (panel && cfg.advanced) ? sensors?.read(onAC: power.isOnAC(now: now)) : nil
        let powerReading = power.read(now: now, panel: panel, sensors: sensorValues)

        let thermal = ThermalReading(state: ProcessInfo.processInfo.thermalState,
                                     cpuTempC: sensorValues?.cpuTempC, gpuTempC: sensorValues?.gpuTempC,
                                     socTempC: sensorValues?.socTempC, fans: sensorValues?.fans ?? [],
                                     components: sensorValues?.components ?? [])

        var ranking: ProcessRanking?
        if panel && now + second / 10 >= processDueNs {
            ranking = processes.sample(now: now)
            processDueNs = now + SystemSampler.processInterval
        }

        let diskReading: DiskReading
        if fullRate || lastDisk == nil {
            diskReading = disk.read(now: now)
            lastDisk = diskReading
        } else {
            diskReading = lastDisk!
        }

        let snapshot = SystemSnapshot(date: Date(), cpu: cpuReading, gpu: panel ? gpu?.read() : nil,
                                      memory: memory.read(), network: networkReading, disk: diskReading,
                                      power: powerReading, thermal: thermal, demand: cfg.demand)
        return SystemSamplerOutput(snapshot: snapshot, processes: ranking, stats: stats)
    }
}

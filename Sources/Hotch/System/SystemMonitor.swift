import Foundation
import Combine

/// A fixed machine state for screenshot / demo modes. Property names match
/// SystemDemo.Data, so the app bridges with one line:
/// `extension SystemDemo.Data: SystemDemoState {}`
protocol SystemDemoState {
    var snapshot: SystemSnapshot { get }
    var cpu: [Double] { get }
    var systemCPU: [Double] { get }
    var gpu: [Double] { get }
    var memory: [Double] { get }
    var down: [Double] { get }
    var up: [Double] { get }
    var read: [Double] { get }
    var write: [Double] { get }
    var power: [Double] { get }
    var topByCPU: [ProcessUsage] { get }
    var topByMemory: [ProcessUsage] { get }
}

/// Main-actor facade the UI binds to. Clients (menu bar, panel, popover, detail
/// views) each state their demand; the monitor samples at the highest one and
/// stops entirely when every client is idle.
@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    static let historyLength = 60

    @Published private(set) var latest: SystemSnapshot?

    // 60 s histories at 1 Hz, oldest first, always `historyLength` long.
    // Pre-filled with the first value (0 before any sample) and re-seeded after
    // a gap of more than 3.5 s, so charts never join stale data to new.
    // Recorded on every tick from menuBar up, but published only while demand is
    // panel or detail (and once the moment the panel opens), so a menuBar-only
    // tick costs one objectWillChange instead of eight.
    /// Total CPU busy, 0...100.
    @Published private(set) var cpuHistory: [Double] = SystemMonitor.zeros
    /// Kernel share of CPU, 0...100.
    @Published private(set) var systemCPUHistory: [Double] = SystemMonitor.zeros
    /// GPU utilisation 0...100. Panel tier only.
    @Published private(set) var gpuHistory: [Double] = SystemMonitor.zeros
    /// Memory used, 0...100.
    @Published private(set) var memoryHistory: [Double] = SystemMonitor.zeros
    /// Bytes per second on the primary interface.
    @Published private(set) var downHistory: [Double] = SystemMonitor.zeros
    @Published private(set) var upHistory: [Double] = SystemMonitor.zeros
    /// Disk bytes per second.
    @Published private(set) var readHistory: [Double] = SystemMonitor.zeros
    @Published private(set) var writeHistory: [Double] = SystemMonitor.zeros
    /// Whole-system watts. Panel tier only.
    @Published private(set) var powerHistory: [Double] = SystemMonitor.zeros

    /// Top 6 by CPU and by memory, refreshed every 2 s while a process list is
    /// visible; emptied as soon as the last list closes.
    @Published private(set) var topByCPU: [ProcessUsage] = []
    @Published private(set) var topByMemory: [ProcessUsage] = []

    /// The highest demand across clients.
    @Published private(set) var effectiveDemand: SystemDemand = .idle

    /// Sampler-thread CPU cost so far (not published; read it for diagnostics).
    private(set) var samplerStats = SystemSamplerStats()

    /// SMC temperatures, fans and power rails, and IOReport CPU clocks. When
    /// false those fields are nil (system watts fall back to battery telemetry).
    var advancedSensors = true {
        didSet { if advancedSensors != oldValue { pushConfig() } }
    }

    private static let zeros = [Double](repeating: 0, count: historyLength)

    private let sampler = SystemSampler()
    /// Set by applyDemo: live samples are ignored until resumeLive().
    private var showingDemo = false
    private var demands: [String: SystemDemand] = [:]
    private var lastConfig = SystemSamplerConfig()

    private var cpuRing = SystemRingBuffer(capacity: SystemMonitor.historyLength)
    private var systemCPURing = SystemRingBuffer(capacity: SystemMonitor.historyLength)
    private var gpuRing = SystemRingBuffer(capacity: SystemMonitor.historyLength)
    private var memoryRing = SystemRingBuffer(capacity: SystemMonitor.historyLength)
    private var downRing = SystemRingBuffer(capacity: SystemMonitor.historyLength)
    private var upRing = SystemRingBuffer(capacity: SystemMonitor.historyLength)
    private var readRing = SystemRingBuffer(capacity: SystemMonitor.historyLength)
    private var writeRing = SystemRingBuffer(capacity: SystemMonitor.historyLength)
    private var powerRing = SystemRingBuffer(capacity: SystemMonitor.historyLength)

    private init() {
        sampler.setOutputHandler { [weak self] output in
            let monitor = self
            DispatchQueue.main.async {
                MainActor.assumeIsolated { monitor?.apply(output) }
            }
        }
    }

    /// Declare what `client` needs. `.idle` removes the client. Cheap to call
    /// repeatedly; the sampler is only reconfigured when the effective demand changes.
    func setDemand(_ demand: SystemDemand, for client: String) {
        if demand == .idle {
            demands.removeValue(forKey: client)
        } else {
            demands[client] = demand
        }
        pushConfig()
    }

    /// Shows a fixed state (snapshot modes) and ignores live samples until resumeLive().
    func applyDemo<State: SystemDemoState>(_ d: State) {
        showingDemo = true
        latest = d.snapshot
        cpuHistory = d.cpu
        systemCPUHistory = d.systemCPU
        gpuHistory = d.gpu
        memoryHistory = d.memory
        downHistory = d.down
        upHistory = d.up
        readHistory = d.read
        writeHistory = d.write
        powerHistory = d.power
        topByCPU = d.topByCPU
        topByMemory = d.topByMemory
    }

    func resumeLive() {
        showingDemo = false
    }

    private func pushConfig() {
        let config = SystemSamplerConfig.resolved(demands: Array(demands.values), advanced: advancedSensors)
        let best = config.demand
        if effectiveDemand != best { effectiveDemand = best }
        if !config.processRanking && !showingDemo {
            if !topByCPU.isEmpty { topByCPU = [] }
            if !topByMemory.isEmpty { topByMemory = [] }
        }
        guard config != lastConfig else { return }
        // Opening the panel while the menu bar tier was running: the rings are
        // live, so charts show the last 60 s at once. From idle the first tick
        // (0.5 s later) re-seeds and publishes them.
        let opening = config.level >= 2 && lastConfig.level == 1
        lastConfig = config
        sampler.update(config)
        if opening && !showingDemo { publishHistories() }
    }

    private func publishHistories() {
        cpuHistory = cpuRing.values
        systemCPUHistory = systemCPURing.values
        memoryHistory = memoryRing.values
        downHistory = downRing.values
        upHistory = upRing.values
        readHistory = readRing.values
        writeHistory = writeRing.values
        gpuHistory = gpuRing.values
        powerHistory = powerRing.values
    }

    private func apply(_ output: SystemSamplerOutput) {
        guard lastConfig.level > 0, !showingDemo else { return } // late tick after going idle, or demo
        let s = output.snapshot
        let d = s.date
        samplerStats = output.stats
        cpuRing.record(s.cpu.total, at: d)
        systemCPURing.record(s.cpu.system, at: d)
        memoryRing.record(s.memory.usedPercent, at: d)
        downRing.record(s.network.downBytesPerSecond, at: d)
        upRing.record(s.network.upBytesPerSecond, at: d)
        readRing.record(s.disk.readBytesPerSecond, at: d)
        writeRing.record(s.disk.writeBytesPerSecond, at: d)
        if let g = s.gpu { gpuRing.record(g.utilization, at: d) }
        if let w = s.power?.systemWatts { powerRing.record(w, at: d) }
        latest = s
        guard lastConfig.level >= 2 else { return }
        publishHistories()
        if lastConfig.processRanking, let p = output.processes {
            topByCPU = p.byCPU
            topByMemory = p.byMemory
        }
    }
}

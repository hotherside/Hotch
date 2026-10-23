import Foundation

// Public value types the UI binds to. Every reading is an immutable value
// produced on the sampler queue and published once per tick on the main actor.
//
// Units: percentages are 0...100, bytes are bytes, rates are bytes per second,
// temperatures are degrees Celsius, power is watts, fan speed is RPM.
// Optional fields are nil when the value was not sampled at the current demand
// tier or the reader is unavailable on this Mac. They are never faked as zero.
// Fields added beyond the original stub carry defaults so hand-built values
// (SystemDemo) keep compiling with the stub's memberwise initialisers.

// MARK: - Demand

enum SystemDetailKind: String, Sendable, CaseIterable {
    case cpu, gpu, memory, network, disk, power
}

/// How much the UI currently needs. Several clients can ask at once; the
/// monitor samples at the highest tier any client asked for.
enum SystemDemand: Sendable, Hashable {
    case idle
    case menuBar
    case panel
    /// A visible process list, such as the Mac overview’s Busiest row.
    case processes
    case detail(SystemDetailKind)

    /// 0 idle, 1 menuBar, 2 panel, 3 detail.
    var rank: Int {
        switch self {
        case .idle: return 0
        case .menuBar: return 1
        case .panel, .processes: return 2
        case .detail: return 3
        }
    }
}

// MARK: - Readings

enum MemoryPressure: Int, Sendable {
    case normal = 1, warning = 2, critical = 4
}

struct CPUReading: Sendable {
    /// Busy share of all logical cores, 0...100 (user + system).
    var total: Double
    /// User share including nice, 0...100.
    var user: Double
    /// Kernel share, 0...100.
    var system: Double
    /// Busy share per logical core, 0...100, in logical CPU id order. 1 s
    /// window in the panel tier; in the menuBar tier it refreshes every 5 s
    /// (5 s averages), since the menu bar shows only the total.
    var perCore: [Double]
    var performanceCoreCount: Int
    var efficiencyCoreCount: Int
    /// Parallel to `perCore`. All false on Intel.
    var isEfficiencyCore: [Bool]
    var loadAverage1: Double
    var loadAverage5: Double = 0
    var loadAverage15: Double = 0
    /// Seconds since boot, sleep included.
    var uptime: TimeInterval
    /// Active-residency weighted cluster clocks in MHz. Only while a
    /// `.detail(.cpu)` client is present and advanced sensors are on; refreshed
    /// every 5 s. A side is nil when that cluster was fully idle for the window.
    /// nil on Intel or when IOReport is unavailable.
    var frequencyMHz: (e: Double?, p: Double?)?

    var loadAverage: (Double, Double, Double) { (loadAverage1, loadAverage5, loadAverage15) }

    /// Mean busy share of efficiency cores, nil when there are none.
    var efficiencyAverage: Double? { average(efficiency: true) }
    /// Mean busy share of performance cores, nil when there are none.
    var performanceAverage: Double? { average(efficiency: false) }

    private func average(efficiency: Bool) -> Double? {
        var sum = 0.0, n = 0
        for (i, v) in perCore.enumerated() where i < isEfficiencyCore.count && isEfficiencyCore[i] == efficiency {
            sum += v; n += 1
        }
        return n > 0 ? sum / Double(n) : nil
    }
}

struct GPUReading: Sendable {
    /// Device utilisation, 0...100.
    var utilization: Double
    /// Unified memory currently in use by the GPU (Apple Silicon), or VRAM in use.
    var memoryUsedBytes: UInt64?
    var coreCount: Int?
    /// For example "Apple M4 Pro".
    var model: String?
}

struct MemoryReading: Sendable {
    var totalBytes: UInt64
    /// app + wired + compressed (Activity Monitor "Memory Used").
    var usedBytes: UInt64
    var appBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    /// File-backed and purgeable pages the system can drop.
    var cachedBytes: UInt64
    var freeBytes: UInt64
    var pressure: MemoryPressure
    /// 100 minus the kernel's available-memory level, 0...100.
    var pressurePercent: Double
    var swapUsedBytes: UInt64
    var swapTotalBytes: UInt64

    var usedPercent: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) * 100 : 0 }
}

struct NetworkReading: Sendable {
    /// Rates on the primary interface. 0 when there is no primary interface (offline).
    var downBytesPerSecond: Double
    var upBytesPerSecond: Double
    /// BSD name, for example "en0". nil when offline.
    var primaryInterface: String?
    var isWiFi: Bool
    var localIPv4: String?
    /// dBm, for example -52. Refreshed by the slow tier (60 s) and every 5 s
    /// while a `.detail(.network)` client is present. nil when not on Wi-Fi.
    var wifiRSSI: Int?
    /// Current link rate in Mbps, same cadence as `wifiRSSI`.
    var wifiTxRateMbps: Double?
    /// Byte counters of the primary interface since it came up (usually boot).
    var totalDownBytes: UInt64
    var totalUpBytes: UInt64
}

struct DiskReading: Sendable {
    /// Boot volume name, for example "Macintosh HD".
    var volumeName: String
    var totalBytes: UInt64
    /// Space available for important usage (what Finder shows as "Available",
    /// purgeable space included). Refreshed by the slow tier.
    var freeBytes: UInt64
    /// Summed over physical block storage (disk images excluded, their IO is
    /// already counted on the disk that holds them). 1 s window in the panel
    /// tier, 5 s averages refreshed every 5 s in the menuBar tier.
    var readBytesPerSecond: Double
    var writeBytesPerSecond: Double
}

struct PowerReading: Sendable {
    /// 0...100. Meaningless when `hasBattery` is false.
    var batteryPercent: Double
    var isCharging: Bool
    var isOnAC: Bool
    /// Time to empty on battery, time to full while charging. nil while the
    /// estimate is being calculated, when on AC and not charging, or unknown.
    var minutesRemaining: Int?
    /// Whole-system draw. Panel tier only. SMC PSTR when advanced sensors are
    /// on, else the battery gauge's telemetry (updates every ~20 s).
    var systemWatts: Double?
    /// Signed: negative while discharging, positive while charging. Panel tier
    /// only. On battery with advanced sensors it is SMC PPBR (real time);
    /// otherwise the battery gauge's voltage x current, which refreshes slowly.
    var batteryWatts: Double?
    /// Live power coming in from the adapter (SMC PDTR, else gauge telemetry).
    /// Panel tier, on AC only.
    var adapterWatts: Double?
    /// Nameplate rating of the connected adapter, for example 96.
    var adapterRatedWatts: Double?
    /// Nominal full-charge capacity over design capacity, can exceed 100 on new
    /// batteries. Slow tier.
    var healthPercent: Double?
    /// Slow tier.
    var cycleCount: Int?
    /// Panel tier.
    var batteryTempC: Double?
    var hasBattery: Bool
    var isFullyCharged: Bool = false
}

struct FanReading: Sendable {
    var rpm: Double
    var minRPM: Double
    var maxRPM: Double
}

/// One part of the Mac and how hot it is, for the Temperatures tile.
struct ComponentTemp: Sendable, Identifiable {
    enum Part: String, Sendable {
        case performanceCores, efficiencyCores, cpu, gpu, chip, ssd, battery, wifi
    }
    var part: Part
    var tempC: Double
    var id: String { part.rawValue }

    var name: String {
        switch part {
        case .performanceCores: return "P-cores"
        case .efficiencyCores: return "E-cores"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .chip: return "Chip"
        case .ssd: return "SSD"
        case .battery: return "Battery"
        case .wifi: return "Wi-Fi"
        }
    }

    var symbol: String {
        switch part {
        case .performanceCores, .cpu: return "cpu.fill"
        case .efficiencyCores: return "cpu"
        case .gpu: return "cube.transparent"
        case .chip: return "square.grid.3x3.square"
        case .ssd: return "internaldrive"
        case .battery: return "battery.75percent"
        case .wifi: return "wifi"
        }
    }

    /// Where this part starts to run warm, and hot. Cores and the GPU work
    /// at 90°C under load without harm; a battery or SSD at that heat is a
    /// problem.
    var warmAt: Double {
        switch part {
        case .battery: return 38
        case .ssd: return 60
        case .wifi: return 65
        default: return 80
        }
    }

    var hotAt: Double {
        switch part {
        case .battery: return 45
        case .ssd: return 70
        case .wifi: return 80
        default: return 95
        }
    }
}

struct ThermalReading: Sendable {
    var state: ProcessInfo.ThermalState
    /// Hottest valid CPU die sensor (SMC). Panel tier with advanced sensors.
    var cpuTempC: Double?
    /// Hottest valid GPU sensor (SMC). Panel tier with advanced sensors.
    var gpuTempC: Double?
    /// Hottest valid SoC sensor (SMC). Panel tier with advanced sensors.
    var socTempC: Double?
    /// Empty on fanless Macs, below the panel tier, or without advanced sensors.
    var fans: [FanReading]
    /// Each part the sensors cover, hottest sensor per part. Panel tier with
    /// advanced sensors.
    var components: [ComponentTemp] = []
}

struct SystemSnapshot: Sendable {
    var date: Date
    var cpu: CPUReading
    /// Panel tier only.
    var gpu: GPUReading?
    var memory: MemoryReading
    var network: NetworkReading
    var disk: DiskReading
    /// nil only if IOPowerSources fails entirely. Desktops report `hasBattery == false`.
    var power: PowerReading?
    var thermal: ThermalReading
    /// The effective demand this snapshot was sampled at.
    var demand: SystemDemand = .panel
}

struct ProcessUsage: Sendable, Identifiable {
    /// pid
    var id: Int32
    var name: String
    /// Percent of one core over the last ~2 s window (can exceed 100).
    var cpuPercent: Double
    /// Physical footprint, the Activity Monitor "Memory" column.
    var memoryBytes: UInt64
    var bundleIdentifier: String?
    /// In the memory ranking each row is an app with its helpers summed
    /// (Chrome and its renderers are one row); this is how many processes.
    var processCount: Int = 1
}

import Foundation

/// A believable machine for the snapshot modes: a 14" MacBook Pro (M4 Pro,
/// 8P + 4E, 24 GB) doing a normal afternoon's work. Histories are generated
/// from a fixed seed so two renders of the same mode are pixel-comparable.
enum SystemDemo {
    struct Data {
        var snapshot: SystemSnapshot
        var cpu: [Double]
        var systemCPU: [Double]
        var gpu: [Double]
        var memory: [Double]
        var down: [Double]
        var up: [Double]
        var read: [Double]
        var write: [Double]
        var power: [Double]
        var topByCPU: [ProcessUsage]
        var topByMemory: [ProcessUsage]
    }

    /// Deterministic wander: a mean-reverting walk with an occasional spike.
    static func series(seed: UInt64, count: Int = 60, base: Double, spread: Double,
                       spikeEvery: Int = 0, spike: Double = 0, floor: Double = 0) -> [Double] {
        var state = seed
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) % 10_000) / 10_000
        }
        var value = base
        var out: [Double] = []
        for i in 0..<count {
            value += (base - value) * 0.25 + (next() - 0.5) * spread
            var v = value
            if spikeEvery > 0 && i % spikeEvery == spikeEvery - 1 { v += spike }
            out.append(max(floor, v))
        }
        return out
    }

    static func make(now: Date = Date()) -> Data {
        let gib: UInt64 = 1_073_741_824
        let cpu = series(seed: 7, base: 22, spread: 12, spikeEvery: 17, spike: 30, floor: 3)
        let sys = cpu.map { $0 * 0.28 }
        let down = series(seed: 11, base: 900_000, spread: 900_000, spikeEvery: 13, spike: 2_600_000, floor: 20_000)
        let up = series(seed: 13, base: 86_000, spread: 90_000, floor: 4_000)
        let perCore: [Double] = [31, 18, 44, 12, 25, 9, 14, 21, 48, 37, 55, 33]
        let snapshot = SystemSnapshot(
            date: now,
            cpu: CPUReading(total: cpu.last ?? 22, user: (cpu.last ?? 22) * 0.72, system: (cpu.last ?? 22) * 0.28,
                            perCore: perCore, performanceCoreCount: 8, efficiencyCoreCount: 4,
                            isEfficiencyCore: Array(repeating: false, count: 8) + Array(repeating: true, count: 4),
                            loadAverage1: 3.4, uptime: 214 * 3600),
            gpu: GPUReading(utilization: 8, memoryUsedBytes: 1_900_000_000, coreCount: 16),
            memory: MemoryReading(totalBytes: 24 * gib,
                                  usedBytes: UInt64(17.1 * Double(gib)),
                                  appBytes: UInt64(9.8 * Double(gib)),
                                  wiredBytes: UInt64(3.1 * Double(gib)),
                                  compressedBytes: UInt64(4.2 * Double(gib)),
                                  cachedBytes: UInt64(5.4 * Double(gib)),
                                  freeBytes: UInt64(1.5 * Double(gib)),
                                  pressure: .normal, pressurePercent: 38,
                                  swapUsedBytes: UInt64(0.8 * Double(gib)), swapTotalBytes: 2 * gib),
            network: NetworkReading(downBytesPerSecond: down.last ?? 1_200_000, upBytesPerSecond: up.last ?? 86_000,
                                    primaryInterface: "en0", isWiFi: true, localIPv4: "192.168.1.24",
                                    wifiRSSI: -47, wifiTxRateMbps: 866,
                                    totalDownBytes: 54 * gib, totalUpBytes: 6 * gib),
            disk: DiskReading(volumeName: "Macintosh HD", totalBytes: 460 * gib, freeBytes: 154 * gib,
                              readBytesPerSecond: 12_400_000, writeBytesPerSecond: 3_900_000),
            power: PowerReading(batteryPercent: 93, isCharging: false, isOnAC: false, minutesRemaining: 387,
                                systemWatts: 11.4, batteryWatts: 11.4, adapterWatts: nil,
                                healthPercent: 96, cycleCount: 149, batteryTempC: 31.5, hasBattery: true),
            thermal: ThermalReading(state: .nominal, cpuTempC: 54, gpuTempC: 47, socTempC: 49,
                                    fans: [FanReading(rpm: 0, minRPM: 2317, maxRPM: 7826),
                                           FanReading(rpm: 0, minRPM: 2317, maxRPM: 7826)],
                                    components: [
                                        ComponentTemp(part: .performanceCores, tempC: 84.2),
                                        ComponentTemp(part: .efficiencyCores, tempC: 48.6),
                                        ComponentTemp(part: .gpu, tempC: 47.1),
                                        ComponentTemp(part: .chip, tempC: 49.3),
                                        ComponentTemp(part: .ssd, tempC: 71.0),
                                        ComponentTemp(part: .battery, tempC: 31.5),
                                        ComponentTemp(part: .wifi, tempC: 44.1),
                                    ])
        )
        let mb: UInt64 = 1_048_576
        return Data(
            snapshot: snapshot,
            cpu: cpu, systemCPU: sys,
            gpu: series(seed: 17, base: 9, spread: 8, floor: 1),
            memory: series(seed: 19, base: 71, spread: 1.4, floor: 50),
            down: down, up: up,
            read: series(seed: 23, base: 9_000_000, spread: 14_000_000, spikeEvery: 21, spike: 60_000_000),
            write: series(seed: 29, base: 3_000_000, spread: 6_000_000),
            power: series(seed: 31, base: 11.4, spread: 3.2, spikeEvery: 17, spike: 9, floor: 4),
            topByCPU: [
                ProcessUsage(id: 401, name: "Claude", cpuPercent: 14.2, memoryBytes: 3_900 * mb, bundleIdentifier: "com.anthropic.claudefordesktop"),
                ProcessUsage(id: 402, name: "Code Helper (Renderer)", cpuPercent: 4.0, memoryBytes: 1_600 * mb, bundleIdentifier: nil),
                ProcessUsage(id: 403, name: "Safari", cpuPercent: 2.2, memoryBytes: 2_100 * mb, bundleIdentifier: "com.apple.Safari"),
                ProcessUsage(id: 404, name: "ChatGPT", cpuPercent: 1.6, memoryBytes: 820 * mb, bundleIdentifier: nil),
                ProcessUsage(id: 405, name: "Terminal", cpuPercent: 0.9, memoryBytes: 140 * mb, bundleIdentifier: nil),
                ProcessUsage(id: 406, name: "Hotch", cpuPercent: 0.3, memoryBytes: 46 * mb, bundleIdentifier: "com.hojaejung.hotch"),
            ],
            topByMemory: [
                ProcessUsage(id: 401, name: "Claude", cpuPercent: 14.2, memoryBytes: 3_900 * mb, bundleIdentifier: nil),
                ProcessUsage(id: 403, name: "Safari", cpuPercent: 2.2, memoryBytes: 2_100 * mb, bundleIdentifier: nil),
                ProcessUsage(id: 402, name: "Code Helper (Renderer)", cpuPercent: 4.0, memoryBytes: 1_600 * mb, bundleIdentifier: nil),
                ProcessUsage(id: 404, name: "ChatGPT", cpuPercent: 1.6, memoryBytes: 820 * mb, bundleIdentifier: nil),
                ProcessUsage(id: 407, name: "node", cpuPercent: 0.4, memoryBytes: 610 * mb, bundleIdentifier: nil),
                ProcessUsage(id: 406, name: "Hotch", cpuPercent: 0.3, memoryBytes: 46 * mb, bundleIdentifier: nil),
            ]
        )
    }
}

/// Lets the real monitor take the demo fixture.
extension SystemDemo.Data: SystemDemoState {}

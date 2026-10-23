import Foundation
import IOKit
import IOKit.ps
import notify

/// Battery and power. Basics come from public IOPowerSources and are re-read
/// only when the "com.apple.system.powersources" notification fires (a
/// notify_check costs ~0.02 us), with a 30 s safety refresh. Watts are panel
/// tier only. Health and cycles are slow tier. AppleSmartBattery is read key by
/// key, never as a whole dictionary.
final class PowerReader {
    private struct Basics {
        var hasBattery = false
        var percent = 0.0
        var isCharging = false
        var isOnAC = true
        var isCharged = false
        var minutes: Int?
    }

    private var token: Int32 = -1
    private var basics: Basics?
    private var basicsNs: UInt64 = 0
    private let battery: io_registry_entry_t
    private var health: Double?
    private var cycles: Int?
    private var ratedWatts: Double?
    private var lastOnAC: Bool?
    private var registryTemp: Double?
    private var registryTempNs: UInt64 = 0
    private var iopsFailed = false

    init() {
        battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if notify_register_check(kIOPSNotifyAnyPowerSource, &token) != UInt32(NOTIFY_STATUS_OK) { token = -1 }
    }

    deinit {
        if token != -1 { notify_cancel(token) }
        if battery != 0 { IOObjectRelease(battery) }
    }

    // MARK: Basics (IOPowerSources)

    private func readBasics() -> Basics? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        var b = Basics()
        if let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? {
            b.isOnAC = type == kIOPSACPowerValue
        }
        if let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                      (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                      (d[kIOPSIsPresentKey] as? Bool) ?? true else { continue }
                b.hasBattery = true
                let cur = (d[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 0
                let max = (d[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100
                b.percent = max > 0 ? min(100, Swift.max(0, cur / max * 100)) : 0
                b.isCharging = (d[kIOPSIsChargingKey] as? Bool) ?? false
                b.isCharged = (d[kIOPSIsChargedKey] as? Bool) ?? false
                if let state = d[kIOPSPowerSourceStateKey] as? String { b.isOnAC = state == kIOPSACPowerValue }
                let toEmpty = (d[kIOPSTimeToEmptyKey] as? NSNumber)?.intValue ?? -1
                let toFull = (d[kIOPSTimeToFullChargeKey] as? NSNumber)?.intValue ?? -1
                if b.isCharging {
                    b.minutes = toFull > 0 ? toFull : nil
                } else if !b.isOnAC {
                    b.minutes = toEmpty > 0 ? toEmpty : nil
                }
                break
            }
        }
        return b
    }

    private func currentBasics(now: UInt64) -> Basics? {
        var changed: Int32 = 1
        if token != -1 { notify_check(token, &changed) }
        if basics == nil || changed != 0 || now &- basicsNs > 30_000_000_000 {
            if let b = readBasics() {
                basics = b
                iopsFailed = false
            } else {
                iopsFailed = true
            }
            basicsNs = now
        }
        return iopsFailed ? nil : basics
    }

    /// Cached AC state (re-read only when the power-source notification fired).
    func isOnAC(now: UInt64) -> Bool { currentBasics(now: now)?.isOnAC ?? false }

    // MARK: Registry helpers

    private let kInstantAmperage = "InstantAmperage" as CFString
    private let kVoltage = "Voltage" as CFString
    private let kTemperature = "Temperature" as CFString
    private let kTelemetry = "PowerTelemetryData" as CFString
    private let kSystemLoad = "SystemLoad" as NSString
    private let kSystemPowerIn = "SystemPowerIn" as NSString

    private func number(_ key: CFString) -> NSNumber? {
        guard battery != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(battery, key, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
    }

    private func number(_ key: String) -> NSNumber? { number(key as CFString) }

    private func dictionary(_ key: CFString) -> NSDictionary? {
        guard battery != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(battery, key, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSDictionary
    }

    /// Slow tier: health, cycle count, adapter rating.
    func refreshSlow() {
        refreshAdapter()
        guard battery != 0 else { return }
        let data = dictionary("BatteryData" as CFString)
        func value(_ k: String) -> Double? {
            (data?[k as NSString] as? NSNumber)?.doubleValue ?? number(k)?.doubleValue
        }
        let design = value("DesignCapacity")
        var full = value("NominalChargeCapacity") ?? value("AppleRawMaxCapacity")
        if full == nil, let m = number("MaxCapacity")?.doubleValue, m > 100 { full = m } // Intel reports mAh here
        if let d = design, d > 0, let f = full, f > 0 {
            let h = f / d * 100
            health = h < 200 ? h : nil
        }
        if let c = number("CycleCount")?.intValue ?? (data?["CycleCount" as NSString] as? NSNumber)?.intValue, c >= 0 {
            cycles = c
        }
        if let t = number("Temperature")?.doubleValue, t > 0 { registryTemp = t / 100 }
    }

    private func refreshAdapter() {
        guard let d = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
              let w = (d[kIOPSPowerAdapterWattsKey] as? NSNumber)?.doubleValue, w > 0 else {
            ratedWatts = nil
            return
        }
        ratedWatts = w
    }

    // MARK: Read

    /// `sensors` is non-nil only in the panel tier with advanced sensors on.
    func read(now: UInt64, panel: Bool, sensors: SensorsReader.Values?) -> PowerReading? {
        guard let b = currentBasics(now: now) else { return nil }
        if lastOnAC != b.isOnAC {
            lastOnAC = b.isOnAC
            refreshAdapter()
        }
        var systemW: Double?, batteryW: Double?, adapterW: Double?, temp: Double?
        if panel {
            systemW = sensors?.systemWatts
            var telemetry: NSDictionary?
            if systemW == nil || (b.isOnAC && sensors?.adapterWatts == nil) {
                telemetry = dictionary(kTelemetry)
            }
            if systemW == nil, let load = (telemetry?[kSystemLoad] as? NSNumber)?.doubleValue, load > 0 {
                systemW = load / 1000
            }
            if b.hasBattery {
                if !b.isOnAC, let p = sensors?.batteryWatts {
                    // SMC PPBR is the real-time discharge power. It does not measure
                    // charging (reads ~1 W while the gauge shows 32 W going in).
                    batteryW = -p
                } else if let a = number(kInstantAmperage)?.doubleValue, let v = number(kVoltage)?.doubleValue, v > 0 {
                    batteryW = v * a / 1_000_000 // gauge, signed: mV x mA
                }
            }
            if b.isOnAC {
                if let a = sensors?.adapterWatts, a > 0.05 { adapterW = a }
                else if let pin = (telemetry?[kSystemPowerIn] as? NSNumber)?.doubleValue, pin > 0 { adapterW = pin / 1000 }
            }
            if b.hasBattery {
                if let t = sensors?.batteryTempC {
                    temp = t
                } else {
                    // Intel exposes Temperature on the battery node; Apple Silicon does not.
                    if now &- registryTempNs > 10_000_000_000 {
                        registryTempNs = now
                        registryTemp = number(kTemperature).map { $0.doubleValue / 100 }.flatMap { $0 > 0 ? $0 : nil }
                    }
                    temp = registryTemp
                }
            }
        }
        return PowerReading(batteryPercent: b.percent, isCharging: b.isCharging, isOnAC: b.isOnAC,
                            minutesRemaining: b.minutes, systemWatts: systemW, batteryWatts: batteryW,
                            adapterWatts: adapterW, adapterRatedWatts: b.isOnAC ? ratedWatts : nil,
                            healthPercent: b.hasBattery ? health : nil, cycleCount: b.hasBattery ? cycles : nil,
                            batteryTempC: temp, hasBattery: b.hasBattery, isFullyCharged: b.isCharged)
    }
}

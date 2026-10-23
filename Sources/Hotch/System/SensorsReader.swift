import Foundation
import Darwin
import IOKit

// MARK: - SMC user client

/// A key resolved once (code, size, type) so per-tick reads skip the info call.
struct SMCKeyInfo {
    let code: UInt32
    let size: UInt32
    let type: UInt32
}

/// Minimal AppleSMC user client. Works unentitled and under hardened runtime.
/// SMCKeyData_t is 80 bytes: key@0, keyInfo.dataSize@28, keyInfo.dataType@32,
/// result@40, data8@42 (command), data32@44 (index), bytes@48.
final class SMCConnection {
    private var conn: io_connect_t = 0
    private let inBuf = UnsafeMutableRawPointer.allocate(byteCount: 80, alignment: 16)
    private let outBuf = UnsafeMutableRawPointer.allocate(byteCount: 80, alignment: 16)

    static func code(_ s: String) -> UInt32 { s.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) } }

    private static let tFlt = code("flt "), tSp78 = code("sp78"), tFpe2 = code("fpe2"), tFp88 = code("fp88")
    private static let tUi8 = code("ui8 "), tUi16 = code("ui16"), tUi32 = code("ui32"), tIoft = code("ioft"), tSi16 = code("si16")

    init?() {
        for name in ["AppleSMC", "AppleSMCKeysEndpoint"] {
            let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
            guard svc != 0 else { continue }
            let kr = IOServiceOpen(svc, mach_task_self_, 0, &conn)
            IOObjectRelease(svc)
            if kr == KERN_SUCCESS { return }
            conn = 0
        }
        return nil // deinit frees the buffers
    }

    deinit {
        if conn != 0 { IOServiceClose(conn) }
        inBuf.deallocate()
        outBuf.deallocate()
    }

    private func call(command: UInt8, key: UInt32, size: UInt32 = 0, index: UInt32 = 0) -> Bool {
        memset(inBuf, 0, 80)
        inBuf.storeBytes(of: key, toByteOffset: 0, as: UInt32.self)
        inBuf.storeBytes(of: size, toByteOffset: 28, as: UInt32.self)
        inBuf.storeBytes(of: command, toByteOffset: 42, as: UInt8.self)
        inBuf.storeBytes(of: index, toByteOffset: 44, as: UInt32.self)
        var outSize = 80
        let kr = IOConnectCallStructMethod(conn, 2, inBuf, 80, outBuf, &outSize)
        return kr == KERN_SUCCESS && outBuf.load(fromByteOffset: 40, as: UInt8.self) == 0
    }

    func info(_ code: UInt32) -> SMCKeyInfo? {
        guard call(command: 9, key: code) else { return nil }
        let size = outBuf.load(fromByteOffset: 28, as: UInt32.self)
        let type = outBuf.load(fromByteOffset: 32, as: UInt32.self)
        guard size > 0, size <= 32 else { return nil }
        return SMCKeyInfo(code: code, size: size, type: type)
    }

    func key(at index: UInt32) -> UInt32? {
        guard call(command: 8, key: 0, index: index) else { return nil }
        return outBuf.load(fromByteOffset: 0, as: UInt32.self)
    }

    func keyCount() -> Int {
        guard let k = info(SMCConnection.code("#KEY")), let v = read(k) else { return 0 }
        return Int(v)
    }

    static func decodable(_ type: UInt32) -> Bool {
        [tFlt, tSp78, tFpe2, tFp88, tUi8, tUi16, tUi32, tIoft, tSi16].contains(type)
    }

    func read(_ k: SMCKeyInfo) -> Double? {
        guard call(command: 5, key: k.code, size: k.size) else { return nil }
        func b(_ i: Int) -> UInt32 { UInt32(outBuf.load(fromByteOffset: 48 + i, as: UInt8.self)) }
        let v: Double
        switch k.type {
        case SMCConnection.tFlt:
            guard k.size >= 4 else { return nil }
            v = Double(outBuf.load(fromByteOffset: 48, as: Float.self))
        case SMCConnection.tSp78:
            v = Double(Int16(bitPattern: UInt16(b(0) << 8 | b(1)))) / 256
        case SMCConnection.tFpe2:
            v = Double(b(0) << 8 | b(1)) / 4
        case SMCConnection.tFp88:
            v = Double(b(0) << 8 | b(1)) / 256
        case SMCConnection.tSi16:
            v = Double(Int16(bitPattern: UInt16(b(0) << 8 | b(1))))
        case SMCConnection.tUi8:
            v = Double(b(0))
        case SMCConnection.tUi16:
            v = Double(b(0) << 8 | b(1))
        case SMCConnection.tUi32:
            v = Double(b(0) << 24 | b(1) << 16 | b(2) << 8 | b(3))
        case SMCConnection.tIoft:
            guard k.size >= 8 else { return nil }
            v = Double(outBuf.load(fromByteOffset: 48, as: UInt64.self)) / 65536
        default:
            return nil
        }
        return v.isFinite ? v : nil
    }
}

// MARK: - Sensors

/// SMC temperatures, fans and power rails. Key families are discovered once
/// (enumerating ~3,400 keys and test-reading the candidates costs ~60 ms wall,
/// once, on the sampler queue), then a capped subset is read per tick (~20 keys,
/// ~0.35 ms CPU). Readings outside 20...130 C are dropped every tick: parked
/// P-core keys read between -4 and 5 C on M4. Group values are the hottest valid
/// sensor. Keys that fail 5 reads in a row are dropped.
final class SensorsReader {
    struct Values: Sendable {
        var components: [ComponentTemp] = []
        var cpuTempC: Double?
        var gpuTempC: Double?
        var socTempC: Double?
        var batteryTempC: Double?
        var fans: [FanReading] = []
        var systemWatts: Double?
        var batteryWatts: Double?
        var adapterWatts: Double?
    }

    private struct Slot {
        let key: SMCKeyInfo
        var misses = 0
    }

    private struct Fan {
        var actual: Slot
        let minKey: SMCKeyInfo?
        let maxKey: SMCKeyInfo?
        var minRPM = 0.0
        var maxRPM = 0.0
    }

    private let smc: SMCConnection
    /// Performance cores, or the whole CPU where the chip does not split them.
    private var pCores: [Slot] = []
    private var eCores: [Slot] = []
    private var gpu: [Slot] = []
    private var soc: [Slot] = []
    private var ssd: [Slot] = []
    private var wifi: [Slot] = []
    private var battery: [Slot] = []
    private var fans: [Fan] = []
    private var systemPower: Slot?
    private var batteryPower: Slot?
    private var adapterPower: Slot?
    private var ticks: UInt64 = 0
    private var batteryTemp: Double?
    /// Each part's last real reading. When a cluster powers down every one
    /// of its sensors reads a placeholder; the part keeps its last reading
    /// for a minute rather than vanishing from the tile.
    private var held: [ComponentTemp.Part: (value: Double, tick: UInt64)] = [:]

    private func steady(_ part: ComponentTemp.Part, _ value: Double?) -> Double? {
        if let value {
            held[part] = (value, ticks)
            return value
        }
        guard let last = held[part], ticks - last.tick <= 60 else { return nil }
        return last.value
    }

    private static let dieRange = 20.0...130.0
    /// SSD and Wi-Fi run cooler than the die and can sit near room heat.
    private static let partRange = 10.0...110.0
    private static let batteryRange = 1.0...80.0

    init?() {
        guard let smc = SMCConnection() else { return nil }
        self.smc = smc

        var codes: [UInt32] = []
        let count = min(smc.keyCount(), 10_000)
        codes.reserveCapacity(count)
        for i in 0..<count { if let k = smc.key(at: UInt32(i)) { codes.append(k) } }
        if codes.isEmpty { codes = SensorsReader.fallbackKeys.map(SMCConnection.code) }
        codes.sort()

        func ch(_ c: UInt32, _ i: Int) -> UInt8 { UInt8((c >> (24 - 8 * UInt32(i))) & 0xff) }
        func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
        let T = UInt8(ascii: "T")

        var cpuCodes: [UInt32] = [], eCodes: [UInt32] = [], gpuCodes: [UInt32] = [], socCodes: [UInt32] = []
        var batteryCodes: [UInt32] = []
        #if arch(arm64)
        for c in codes where ch(c, 0) == T {
            let c1 = ch(c, 1), c2 = ch(c, 2), c3 = ch(c, 3)
            if c1 == UInt8(ascii: "p") || (c1 == UInt8(ascii: "f") && (c2 == UInt8(ascii: "0") || c2 == UInt8(ascii: "4"))) {
                cpuCodes.append(c) // Tp* P-cores (M1, M2, M4), Tf0*/Tf4* (M3)
            } else if c1 == UInt8(ascii: "e") {
                eCodes.append(c) // Te* E-cores
            } else if c1 == UInt8(ascii: "g") || (c1 == UInt8(ascii: "f") && (c2 == UInt8(ascii: "1") || c2 == UInt8(ascii: "2"))) {
                gpuCodes.append(c) // Tg*, Tf1*/Tf2* (M3)
            } else if c1 == UInt8(ascii: "s") && c3 != UInt8(ascii: "P") {
                socCodes.append(c) // Ts* die sensors; Ts0P/Ts1P are palm-rest skin sensors
            } else if c1 == UInt8(ascii: "B") && isDigit(c2) && c3 == T {
                batteryCodes.append(c)
            }
        }
        #else
        let present = Set(codes)
        func known(_ list: [String]) -> [UInt32] { list.map(SMCConnection.code).filter { present.contains($0) } }
        cpuCodes = known(["TC0P", "TC0D", "TC0E", "TC0F", "TC0H", "TC0C", "TCXC", "TC1C", "TC2C", "TC3C", "TC4C", "TC5C", "TC6C", "TC7C", "TC8C"])
        gpuCodes = known(["TG0P", "TG0D", "TGDD", "TG0H", "TG1D"])
        socCodes = known(["TPCD"])
        batteryCodes = codes.filter { ch($0, 0) == T && ch($0, 1) == UInt8(ascii: "B") && isDigit(ch($0, 2)) && ch($0, 3) == T }
        #endif

        // Storage (TH0a/TH0b/TH0x, the NAND on Apple silicon) and Wi-Fi
        // (TW0P) read the same way on every Mac that has them.
        let ssdCodes = codes.filter { ch($0, 0) == T && ch($0, 1) == UInt8(ascii: "H") && ch($0, 2) == UInt8(ascii: "0") }
        let wifiCodes = codes.filter { $0 == SMCConnection.code("TW0P") }

        // M4 Pro has ~110 P-core keys, half of them parked placeholders;
        // watching more keeps a real one in the set as cores park and wake.
        pCores = pick(cpuCodes, limit: 12, range: SensorsReader.dieRange)
        eCores = pick(eCodes, limit: 4, range: SensorsReader.dieRange)
        gpu = pick(gpuCodes, limit: 4, range: SensorsReader.dieRange)
        ssd = pick(ssdCodes, limit: 2, range: SensorsReader.partRange)
        wifi = pick(wifiCodes, limit: 1, range: SensorsReader.partRange)
        soc = pick(socCodes, limit: 3, range: SensorsReader.dieRange)
        battery = pick(batteryCodes, limit: 3, range: SensorsReader.batteryRange)

        func slot(_ name: String) -> Slot? {
            guard let k = smc.info(SMCConnection.code(name)), SMCConnection.decodable(k.type), smc.read(k) != nil else { return nil }
            return Slot(key: k)
        }
        systemPower = slot("PSTR")
        batteryPower = slot("PPBR")
        adapterPower = slot("PDTR")

        if let n = slot("FNum").flatMap({ smc.read($0.key) }) {
            for i in 0..<min(Int(n), 8) {
                guard let ac = slot("F\(i)Ac") else { continue }
                fans.append(Fan(actual: ac, minKey: smc.info(SMCConnection.code("F\(i)Mn")), maxKey: smc.info(SMCConnection.code("F\(i)Mx"))))
            }
            refreshFanLimits()
        }

        if pCores.isEmpty && eCores.isEmpty && gpu.isEmpty && soc.isEmpty && fans.isEmpty && systemPower == nil { return nil }
    }

    /// Used only if key enumeration fails (Stats-style per-chip lists).
    private static let fallbackKeys = ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0T", "Tp0X", "Tp0b",
                                       "Tf04", "Tf09", "Tf0A", "Tf0B", "Tg05", "Tg0D", "Tg0f", "Tg0j", "Tg1U", "Tg1k", "Tf14", "Tf18",
                                       "Ts00", "Ts01", "TB0T", "TB1T", "TB2T", "TC0P", "TC0D", "TC0E", "TC0F", "TG0P", "TG0D", "TPCD"]

    /// Prefers keys that read a plausible, non-integer value now (exact integers
    /// such as 40.0 are placeholders on parked cores), spread evenly across the
    /// family, then tops up with the rest so parked sensors still count when awake.
    private func pick(_ codes: [UInt32], limit: Int, range: ClosedRange<Double>) -> [Slot] {
        var good: [SMCKeyInfo] = [], other: [SMCKeyInfo] = []
        for c in codes {
            guard let k = smc.info(c), SMCConnection.decodable(k.type) else { continue }
            if let v = smc.read(k), range.contains(v), v != v.rounded() { good.append(k) } else { other.append(k) }
        }
        func spread(_ a: [SMCKeyInfo], _ n: Int) -> [SMCKeyInfo] {
            guard n > 0 else { return [] }
            guard a.count > n else { return a }
            return (0..<n).map { a[$0 * a.count / n] }
        }
        let chosen = spread(good, limit) + spread(other, limit - min(limit, good.count))
        return chosen.map { Slot(key: $0) }
    }

    func refreshFanLimits() {
        for i in fans.indices {
            if let k = fans[i].minKey, let v = smc.read(k), v >= 0 { fans[i].minRPM = v }
            if let k = fans[i].maxKey, let v = smc.read(k), v > 0 { fans[i].maxRPM = v }
        }
    }

    /// The hottest real reading. On the die, an exact whole number is a
    /// parked sensor's placeholder (M4 Pro's idle P-core keys all read
    /// 40.00), never a measurement, so it does not count.
    private func hottest(_ slots: inout [Slot], _ range: ClosedRange<Double>, placeholders: Bool = false) -> Double? {
        var best: Double?
        var dropped = false
        for i in slots.indices {
            if let v = smc.read(slots[i].key) {
                slots[i].misses = 0
                if range.contains(v), !placeholders || v != v.rounded() { best = max(best ?? v, v) }
            } else {
                slots[i].misses += 1
                if slots[i].misses >= 5 { dropped = true }
            }
        }
        if dropped { slots.removeAll { $0.misses >= 5 } }
        return best
    }

    private func value(_ slot: inout Slot?, _ range: ClosedRange<Double>) -> Double? {
        guard var s = slot else { return nil }
        let v = smc.read(s.key)
        if v == nil { s.misses += 1 } else { s.misses = 0 }
        slot = s.misses >= 5 ? nil : s
        guard let v, range.contains(v) else { return nil }
        return v
    }

    func read(onAC: Bool) -> Values {
        ticks += 1
        var out = Values()
        let pPart: ComponentTemp.Part = eCores.isEmpty ? .cpu : .performanceCores
        let p = steady(pPart, hottest(&pCores, SensorsReader.dieRange, placeholders: true))
        let e = steady(.efficiencyCores, hottest(&eCores, SensorsReader.dieRange, placeholders: true))
        out.cpuTempC = [p, e].compactMap { $0 }.max()
        out.gpuTempC = steady(.gpu, hottest(&gpu, SensorsReader.dieRange, placeholders: true))
        out.socTempC = steady(.chip, hottest(&soc, SensorsReader.dieRange, placeholders: true))
        let storage = hottest(&ssd, SensorsReader.partRange)
        let radio = hottest(&wifi, SensorsReader.partRange)
        if ticks % 10 == 1 {
            // Battery temperature moves slowly; read every 10 ticks and average the cells.
            var sum = 0.0, n = 0.0
            for s in battery {
                if let v = smc.read(s.key), SensorsReader.batteryRange.contains(v) { sum += v; n += 1 }
            }
            batteryTemp = n > 0 ? sum / n : nil
        }
        out.batteryTempC = batteryTemp
        // Without separate efficiency cores (Intel), the CPU is one part.
        let parts: [(ComponentTemp.Part, Double?)] = [
            (pPart, p), (.efficiencyCores, e), (.gpu, out.gpuTempC),
            (.chip, out.socTempC), (.ssd, storage), (.battery, batteryTemp), (.wifi, radio),
        ]
        out.components = parts.compactMap { part, value in value.map { ComponentTemp(part: part, tempC: $0) } }
        var fanOut: [FanReading] = []
        for i in fans.indices {
            if let v = smc.read(fans[i].actual.key) {
                fans[i].actual.misses = 0
                if v >= 0, v < 20_000 {
                    fanOut.append(FanReading(rpm: v, minRPM: fans[i].minRPM, maxRPM: fans[i].maxRPM))
                }
            } else {
                fans[i].actual.misses += 1
            }
        }
        fans.removeAll { $0.actual.misses >= 5 }
        out.fans = fanOut
        out.systemWatts = value(&systemPower, 0...1_000)
        out.batteryWatts = value(&batteryPower, 0...500)
        out.adapterWatts = onAC ? value(&adapterPower, 0...500) : nil
        return out
    }
}

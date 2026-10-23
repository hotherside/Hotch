import SwiftUI

/// This Mac: iStat-style vitals in six live tiles. A tile opens in place to its
/// detail — a bigger chart and the processes behind the number — and the back
/// button folds it away again.
struct MacSection: View {
    @ObservedObject var system: SystemMonitor
    let detail: SystemDetailKind?
    let active: Bool
    let layout: SectionLayout
    let nav: SectionNav

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let detail {
                MacDetailView(system: system, kind: detail, layout: layout, nav: nav)
                    .transition(HMotion.sectionTransition)
                    .id(detail)
            } else {
                grid
                    .transition(HMotion.sectionTransition)
            }
        }
        .animation(HMotion.detail, value: detail)
        .frame(width: layout.width, alignment: .topLeading)
    }

    private var grid: some View {
        let columns = layout.isPopover ? 2 : 3
        return VStack(spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                if let snap = system.latest {
                    cpuTile(snap)
                    gpuTile(snap)
                    memoryTile(snap)
                    networkTile(snap)
                    diskTile(snap)
                    powerTile(snap)
                } else {
                    ForEach(0..<6, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: HP.tileRadius, style: .continuous)
                            .fill(HP.tile).frame(height: 130)
                    }
                }
            }
            .modifier(Rise(active: active, index: 0))
            busiest
                .modifier(Rise(active: active, index: 1))
        }
    }

    // MARK: Tiles

    private func bigTile<C: View>(_ kind: SystemDetailKind, title: String,
                                  @ViewBuilder content: () -> C) -> some View {
        Button { nav.openDetail(kind) } label: {
            VStack(alignment: .leading, spacing: 7) {
                content()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(height: 130, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(TileButtonStyle())
        .help("\(title) details")
    }

    private func header(_ title: String, value: Double?, text: String, unit: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Kicker(text: title)
            Spacer(minLength: 4)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                RollingNumber(value: value ?? 0, text: text, size: 20, color: color)
                Text(unit).font(.system(size: 11, weight: .semibold)).foregroundStyle(HP.text2)
            }
        }
    }

    private func foot(_ left: String, _ right: String?) -> some View {
        HStack {
            Text(left).lineLimit(1)
            Spacer(minLength: 4)
            if let right { Text(right).lineLimit(1) }
        }
        .font(.system(size: 11))
        .foregroundStyle(HP.text2)
    }

    private func cpuTile(_ snap: SystemSnapshot) -> some View {
        bigTile(.cpu, title: "CPU") {
            header("CPU", value: snap.cpu.total, text: SysFmt.percent(snap.cpu.total), unit: "%", color: HP.cpu)
            Sparkline(values: system.cpuHistory, maxValue: 100, color: HP.cpu,
                      secondary: system.systemCPUHistory)
                .frame(height: 44)
            HStack(alignment: .bottom, spacing: 8) {
                CoreBars(cpu: snap.cpu, height: 14, barWidth: 5)
                Spacer(minLength: 4)
                if let t = SysFmt.temp(snap.thermal.cpuTempC) {
                    Text(t).font(.system(size: 11)).foregroundStyle(HP.text2)
                }
            }
        }
    }

    private func gpuTile(_ snap: SystemSnapshot) -> some View {
        bigTile(.gpu, title: "GPU") {
            header("GPU", value: snap.gpu?.utilization,
                   text: snap.gpu.map { SysFmt.percent($0.utilization) } ?? "—", unit: "%", color: HP.gpu)
            Sparkline(values: system.gpuHistory, maxValue: 100, color: HP.gpu)
                .frame(height: 44)
            foot([snap.gpu?.coreCount.map { "\($0)-core" },
                  snap.gpu?.memoryUsedBytes.map { "\(SysFmt.bytes($0)) in use" }]
                    .compactMap { $0 }.joined(separator: " · "),
                 SysFmt.temp(snap.thermal.gpuTempC))
        }
    }

    private func memoryTile(_ snap: SystemSnapshot) -> some View {
        let m = snap.memory
        return bigTile(.memory, title: "Memory") {
            HStack(alignment: .firstTextBaseline) {
                Kicker(text: "Memory")
                Spacer(minLength: 4)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    RollingNumber(value: Double(m.usedBytes), text: SysFmt.gigabytes(m.usedBytes),
                                  size: 20, color: HP.memory)
                    Text(layout.isPopover ? "GB" : "of \(Int((Double(m.totalBytes) / 1_073_741_824).rounded())) GB")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(HP.text2)
                }
            }
            MemoryBar(memory: m, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                legend("App", m.appBytes, HP.memory)
                legend("Wired", m.wiredBytes, HP.memory.opacity(0.62))
                legend("Compressed", m.compressedBytes, HP.memory.opacity(0.38))
            }
            Spacer(minLength: 0)
            HStack {
                HStack(spacing: 5) {
                    Circle().fill(HP.pressure(m.pressure)).frame(width: 6, height: 6)
                    Text(pressureWord(m.pressure).capitalized)
                        .fontWeight(.semibold)
                        .foregroundStyle(HP.pressure(m.pressure))
                }
                Spacer()
                if m.swapUsedBytes > 0 { Text("Swap \(SysFmt.bytes(m.swapUsedBytes))") }
            }
            .font(.system(size: 11))
            .foregroundStyle(HP.text2)
        }
    }

    private func legend(_ name: String, _ bytes: UInt64, _ color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
            Text(name).foregroundStyle(HP.text2)
            Spacer(minLength: 4)
            Text(SysFmt.bytes(bytes)).foregroundStyle(HP.text2).monospacedDigit()
        }
        .font(.system(size: 10.5))
    }

    private func networkTile(_ snap: SystemSnapshot) -> some View {
        let n = snap.network
        return bigTile(.network, title: "Network") {
            HStack(alignment: .firstTextBaseline) {
                Kicker(text: "Network")
                Spacer(minLength: 4)
                Text(n.isWiFi ? "Wi-Fi" : (n.primaryInterface ?? "offline"))
                    .font(.system(size: 11)).foregroundStyle(HP.text3)
            }
            MirrorSparkline(above: system.downHistory, below: system.upHistory,
                            aboveColor: HP.down, belowColor: HP.up)
                .frame(height: 48)
            HStack {
                (Text("↓ ").foregroundColor(HP.down) + Text(SysFmt.rate(n.downBytesPerSecond)).foregroundColor(HP.text))
                Spacer(minLength: 4)
                (Text("↑ ").foregroundColor(HP.up) + Text(SysFmt.rate(n.upBytesPerSecond)).foregroundColor(HP.text))
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
        }
    }

    private func diskTile(_ snap: SystemSnapshot) -> some View {
        let d = snap.disk
        let used = d.totalBytes > 0 ? 1 - Double(d.freeBytes) / Double(d.totalBytes) : 0
        return bigTile(.disk, title: "Disk") {
            HStack(alignment: .firstTextBaseline) {
                Kicker(text: "Disk")
                Spacer(minLength: 4)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int((Double(d.freeBytes) / 1_073_741_824).rounded()))")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(HP.disk)
                    Text("GB free").font(.system(size: 11, weight: .semibold)).foregroundStyle(HP.text2)
                }
            }
            SegmentBar(segments: [.init(fraction: used, color: HP.disk)], height: 6)
            MirrorSparkline(above: system.readHistory, below: system.writeHistory,
                            aboveColor: HP.disk, belowColor: HP.text2, lineWidth: 1.2)
                .frame(height: 32)
            foot("R \(SysFmt.rate(d.readBytesPerSecond))", "W \(SysFmt.rate(d.writeBytesPerSecond))")
        }
    }

    private func powerTile(_ snap: SystemSnapshot) -> some View {
        bigTile(.power, title: "Power") {
            let watts = snap.power?.systemWatts
            header("Power", value: watts, text: watts.map { String(format: "%.1f", $0) } ?? "—",
                   unit: "W", color: HP.power)
            Sparkline(values: system.powerHistory, color: HP.power)
                .frame(height: 44)
            if let p = snap.power, p.hasBattery {
                foot("\(SysFmt.percent(p.batteryPercent))%"
                     + (p.isCharging ? " · charging" : (SysFmt.minutes(p.minutesRemaining).map { " · \($0) left" } ?? "")),
                     fanText(snap))
            } else {
                foot("On power adapter", fanText(snap))
            }
        }
    }

    private func fanText(_ snap: SystemSnapshot) -> String? {
        guard !snap.thermal.fans.isEmpty else { return nil }
        let rpm = snap.thermal.fans.map(\.rpm).max() ?? 0
        return rpm < 100 ? "Fans off" : "Fans \(Int(rpm)) rpm"
    }

    private func pressureWord(_ p: MemoryPressure) -> String {
        switch p {
        case .normal: return "normal"
        case .warning: return "raised"
        case .critical: return "high"
        }
    }

    // MARK: Busiest strip

    private var busiest: some View {
        HStack(spacing: 14) {
            Kicker(text: "Busiest")
            if system.topByCPU.isEmpty {
                Text("measuring…").foregroundStyle(HP.text3)
            }
            ForEach(system.topByCPU.prefix(layout.isPopover ? 2 : 3)) { p in
                HStack(spacing: 4) {
                    Text(p.name).foregroundStyle(HP.text).lineLimit(1)
                    Text("\(Int(p.cpuPercent.rounded()))%").foregroundStyle(HP.text2).monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            if let snap = system.latest, !layout.isPopover {
                Text("Thermal \(SysFmt.thermal(snap.thermal.state))")
                    .foregroundStyle(snap.thermal.state.rawValue >= 2 ? HP.amber : HP.text3)
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 14)
        .frame(height: 36)
        .tile()
    }
}

/// Per-core load: performance cores full height, efficiency cores dimmer.
struct CoreBars: View {
    let cpu: CPUReading
    var height: CGFloat = 14
    var barWidth: CGFloat = 5
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(cpu.perCore.enumerated()), id: \.offset) { index, load in
                let efficiency = index < cpu.isEfficiencyCore.count ? cpu.isEfficiencyCore[index] : false
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(HP.cpu.opacity(efficiency ? 0.5 : 1))
                    .frame(width: barWidth, height: max(2, height * CGFloat(min(100, max(0, load)) / 100)))
                    .frame(height: height, alignment: .bottom)
                    .background(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(HP.track.opacity(0.5))
                            .frame(width: barWidth, height: height)
                    }
            }
        }
        .frame(height: height, alignment: .bottom)
        .animation(HMotion.tick, value: cpu.perCore)
    }
}

// MARK: - Detail

struct MacDetailView: View {
    @ObservedObject var system: SystemMonitor
    let kind: SystemDetailKind
    let layout: SectionLayout
    let nav: SectionNav

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { nav.openDetail(nil) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        Text("Mac")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .foregroundStyle(HP.text2)
                }
                .buttonStyle(TileButtonStyle(radius: 8))
                Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(HP.text)
                Text(caption).font(.system(size: 11.5)).foregroundStyle(HP.text3).lineLimit(1)
                Spacer(minLength: 4)
                Text(headline)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
                    .animation(HMotion.tick, value: headline)
            }
            .frame(height: 30)

            let chart = VStack(alignment: .leading, spacing: 8) {
                chartView.frame(height: layout.isPopover ? 110 : 150)
                HStack {
                    Text("60 s ago"); Spacer(); Text(legend); Spacer(); Text("now")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(HP.text3)
                if kind == .cpu, let cpu = system.latest?.cpu {
                    CoreBars(cpu: cpu, height: 32, barWidth: 14)
                    HStack {
                        Text("\(cpu.performanceCoreCount) performance cores")
                        Spacer()
                        Text("\(cpu.efficiencyCoreCount) efficiency")
                    }
                    .font(.system(size: 10.5)).foregroundStyle(HP.text3)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: layout.isPopover ? nil : .infinity, alignment: .top)
            .tile()

            let list = VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Text(row.name).foregroundStyle(HP.text).lineLimit(1)
                            if let detail = row.detail {
                                Text(detail).font(.system(size: 10.5)).foregroundStyle(HP.text3).lineLimit(1)
                                    .fixedSize()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let fraction = row.fraction {
                            SegmentBar(segments: [.init(fraction: fraction, color: color)], height: 5)
                                .frame(width: 50)
                        }
                        Text(row.value).foregroundStyle(HP.text2).monospacedDigit()
                            .frame(minWidth: 58, alignment: .trailing)
                    }
                    .font(.system(size: 12))
                    .frame(height: 36)
                    if index < rows.count - 1 { Rectangle().fill(HP.stroke).frame(height: 1) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, maxHeight: layout.isPopover ? nil : .infinity, alignment: .top)
            .tile()

            if layout.isPopover {
                chart
                list
            } else {
                HStack(alignment: .top, spacing: 8) {
                    chart.frame(width: (layout.width - 8) * 0.56)
                    list
                }
                .frame(height: 262)
            }
        }
        .frame(width: layout.width, alignment: .topLeading)
        .onAppear { system.setDemand(.detail(kind), for: "detail") }
        .onDisappear { system.setDemand(.idle, for: "detail") }
    }

    private var snap: SystemSnapshot? { system.latest }

    private var title: String {
        switch kind {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "Memory"
        case .network: return "Network"
        case .disk: return "Disk"
        case .power: return "Power"
        }
    }

    private var color: Color {
        switch kind {
        case .cpu: return HP.cpu
        case .gpu: return HP.gpu
        case .memory: return HP.memory
        case .network: return HP.down
        case .disk: return HP.disk
        case .power: return HP.power
        }
    }

    private var headline: String {
        guard let s = snap else { return "—" }
        switch kind {
        case .cpu: return "\(SysFmt.percent(s.cpu.total))%"
        case .gpu: return s.gpu.map { "\(SysFmt.percent($0.utilization))%" } ?? "—"
        case .memory: return "\(SysFmt.gigabytes(s.memory.usedBytes)) GB"
        case .network: return "↓ \(SysFmt.rate(s.network.downBytesPerSecond))"
        case .disk: return "\(Int((Double(s.disk.freeBytes) / 1_073_741_824).rounded())) GB free"
        case .power: return s.power?.systemWatts.map { String(format: "%.1f W", $0) } ?? "—"
        }
    }

    private var caption: String {
        guard let s = snap else { return "" }
        switch kind {
        case .cpu:
            return "\(s.cpu.performanceCoreCount)P + \(s.cpu.efficiencyCoreCount)E"
                + (SysFmt.temp(s.thermal.cpuTempC).map { " · \($0)" } ?? "")
        case .gpu:
            return [s.gpu?.coreCount.map { "\($0)-core" }, SysFmt.temp(s.thermal.gpuTempC)]
                .compactMap { $0 }.joined(separator: " · ")
        case .memory:
            return "Pressure \(Int(s.memory.pressurePercent.rounded()))% · swap \(SysFmt.bytes(s.memory.swapUsedBytes))"
        case .network:
            return [s.network.isWiFi ? "Wi-Fi" : s.network.primaryInterface, s.network.localIPv4]
                .compactMap { $0 }.joined(separator: " · ")
        case .disk:
            return "\(s.disk.volumeName) · \(SysFmt.bytes(s.disk.totalBytes)) total"
        case .power:
            guard let p = s.power, p.hasBattery else { return "On power adapter" }
            return p.isCharging ? "Charging" : (p.isOnAC ? "On adapter" : "On battery")
        }
    }

    private var legend: String {
        switch kind {
        case .cpu: return "total · dashed is system"
        case .gpu: return "device utilisation"
        case .memory: return "% of memory in use"
        case .network: return "download up · upload down"
        case .disk: return "read up · written down"
        case .power: return "whole-system draw, watts"
        }
    }

    @ViewBuilder
    private var chartView: some View {
        switch kind {
        case .cpu:
            Sparkline(values: system.cpuHistory, maxValue: 100, color: HP.cpu, lineWidth: 2,
                      secondary: system.systemCPUHistory)
        case .gpu:
            Sparkline(values: system.gpuHistory, maxValue: 100, color: HP.gpu, lineWidth: 2)
        case .memory:
            Sparkline(values: system.memoryHistory, maxValue: 100, color: HP.memory, lineWidth: 2)
        case .network:
            MirrorSparkline(above: system.downHistory, below: system.upHistory,
                            aboveColor: HP.down, belowColor: HP.up, lineWidth: 2)
        case .disk:
            MirrorSparkline(above: system.readHistory, below: system.writeHistory,
                            aboveColor: HP.disk, belowColor: HP.text2, lineWidth: 2)
        case .power:
            Sparkline(values: system.powerHistory, color: HP.power, lineWidth: 2)
        }
    }

    private struct Row { let name: String; var detail: String? = nil; let value: String; let fraction: Double? }

    private var rows: [Row] {
        guard let s = snap else { return [] }
        switch kind {
        case .cpu:
            let top = system.topByCPU.prefix(6)
            let peak = max(top.map(\.cpuPercent).max() ?? 1, 1)
            return top.map { Row(name: $0.name, value: String(format: "%.1f%%", $0.cpuPercent),
                                 fraction: $0.cpuPercent / peak) }
        case .memory:
            let top = system.topByMemory.prefix(6)
            let peak = Double(max(top.map(\.memoryBytes).max() ?? 1, 1))
            return top.map { Row(name: $0.name, detail: $0.processCount > 1 ? "\($0.processCount) processes" : nil,
                                 value: SysFmt.bytes($0.memoryBytes),
                                 fraction: Double($0.memoryBytes) / peak) }
        case .gpu:
            return [
                Row(name: "Utilisation", value: s.gpu.map { "\(SysFmt.percent($0.utilization))%" } ?? "—",
                    fraction: (s.gpu?.utilization ?? 0) / 100),
                Row(name: "Memory in use", value: s.gpu?.memoryUsedBytes.map { SysFmt.bytes($0) } ?? "—", fraction: nil),
                Row(name: "Temperature", value: SysFmt.temp(s.thermal.gpuTempC) ?? "—", fraction: nil),
                Row(name: "Cores", value: s.gpu?.coreCount.map(String.init) ?? "—", fraction: nil),
            ]
        case .network:
            let n = s.network
            var r = [
                Row(name: "Download now", value: SysFmt.rate(n.downBytesPerSecond), fraction: nil),
                Row(name: "Upload now", value: SysFmt.rate(n.upBytesPerSecond), fraction: nil),
                Row(name: "Received since boot", value: SysFmt.bytes(n.totalDownBytes), fraction: nil),
                Row(name: "Sent since boot", value: SysFmt.bytes(n.totalUpBytes), fraction: nil),
            ]
            if let rssi = n.wifiRSSI { r.append(Row(name: "Wi-Fi signal", value: "\(rssi) dBm", fraction: nil)) }
            if let tx = n.wifiTxRateMbps { r.append(Row(name: "Link rate", value: "\(Int(tx)) Mbps", fraction: nil)) }
            return r
        case .disk:
            let d = s.disk
            let used = d.totalBytes > d.freeBytes ? d.totalBytes - d.freeBytes : 0
            return [
                Row(name: "Used", value: SysFmt.bytes(used),
                    fraction: d.totalBytes > 0 ? Double(used) / Double(d.totalBytes) : nil),
                Row(name: "Free", value: SysFmt.bytes(d.freeBytes), fraction: nil),
                Row(name: "Reading now", value: SysFmt.rate(d.readBytesPerSecond), fraction: nil),
                Row(name: "Writing now", value: SysFmt.rate(d.writeBytesPerSecond), fraction: nil),
            ]
        case .power:
            var r: [Row] = []
            if let p = s.power, p.hasBattery {
                r.append(Row(name: "Battery", value: "\(SysFmt.percent(p.batteryPercent))%", fraction: p.batteryPercent / 100))
                if let m = SysFmt.minutes(p.minutesRemaining) { r.append(Row(name: "Time left", value: m, fraction: nil)) }
                if let h = p.healthPercent {
                    r.append(Row(name: "Health", value: "\(Int(h.rounded()))%" + (p.cycleCount.map { " · \($0) cycles" } ?? ""),
                                 fraction: h / 100))
                }
                if let t = SysFmt.temp(p.batteryTempC) { r.append(Row(name: "Battery temp", value: t, fraction: nil)) }
                if let w = p.adapterWatts, p.isOnAC { r.append(Row(name: "Adapter", value: "\(Int(w)) W", fraction: nil)) }
            }
            if let w = s.power?.systemWatts { r.append(Row(name: "System draw", value: String(format: "%.1f W", w), fraction: nil)) }
            let fans = s.thermal.fans
            if !fans.isEmpty {
                let rpm = fans.map(\.rpm).max() ?? 0
                r.append(Row(name: "Fans", value: rpm < 100 ? "off" : "\(Int(rpm)) rpm", fraction: nil))
            }
            r.append(Row(name: "Thermal state", value: SysFmt.thermal(s.thermal.state), fraction: nil))
            return Array(r.prefix(6))
        }
    }
}

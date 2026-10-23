import Foundation
import Darwin
import AppKit

struct ProcessRanking: Sendable {
    var byCPU: [ProcessUsage]
    var byMemory: [ProcessUsage]
}

/// Top processes via proc_listallpids + proc_pid_rusage(RUSAGE_INFO_V0).
/// ~0.5 ms warm, ~2.5-3 ms from a cold 1 Hz wake on a Mac with ~450 readable
/// processes, so the sampler calls it every `SystemSampler.processInterval`.
/// V0 already carries CPU time, phys_footprint and start time; newer flavours
/// make the kernel gather counters this never uses.
/// Only processes owned by this user are readable; root and system daemons
/// (WindowServer, kernel_task...) are refused, remembered in a skip list and
/// not asked again until their pid disappears.
final class ProcessReader {
    private struct Sample { var cpuTicks: UInt64; var start: UInt64; var footprint: UInt64 }
    /// `app` groups a process with the app it belongs to: a helper's path
    /// sits inside its app's bundle, so the outermost `.app` names it.
    private struct Name { var start: UInt64; var name: String; var bundle: String?; var app: String }

    private var pids = [pid_t](repeating: 0, count: 2048)
    private var prev: [pid_t: Sample] = [:]
    private var prevNs: UInt64 = 0
    private var denied = Set<pid_t>()
    private var names: [pid_t: Name] = [:]
    private var samples = 0
    private let ticksToNs: Double
    let limit: Int

    init(limit: Int = 6) {
        self.limit = limit
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        // ri_user_time / ri_system_time are mach ticks (125/3 ns on Apple Silicon, 1 ns on Intel).
        ticksToNs = tb.denom > 0 ? Double(tb.numer) / Double(tb.denom) : 1
    }

    func reset() {
        prev = [:]
        prevNs = 0
    }

    private func listPids() -> Int {
        while true {
            let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
            if n <= 0 { return 0 }
            if n < pids.count { return n }
            pids = [pid_t](repeating: 0, count: pids.count * 2)
        }
    }

    private func collect() -> [pid_t: Sample] {
        let n = listPids()
        var out = [pid_t: Sample](minimumCapacity: n)
        var info = rusage_info_v0()
        for i in 0..<n {
            let pid = pids[i]
            if pid <= 0 || denied.contains(pid) { continue }
            let rc = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V0, $0) }
            }
            if rc != 0 { denied.insert(pid); continue }
            out[pid] = Sample(cpuTicks: info.ri_user_time &+ info.ri_system_time,
                              start: info.ri_proc_start_abstime, footprint: info.ri_phys_footprint)
        }
        samples += 1
        if samples % 15 == 0 {
            // Forget pids that are gone so a reused pid is asked again.
            var live = Set<pid_t>(minimumCapacity: n)
            for i in 0..<n { live.insert(pids[i]) }
            denied.formIntersection(live)
            names = names.filter { live.contains($0.key) }
        }
        return out
    }

    func prime(now: UInt64) {
        prev = collect()
        prevNs = now
    }

    func sample(now: UInt64) -> ProcessRanking? {
        let cur = collect()
        defer { prev = cur; prevNs = now }
        guard now > prevNs, !prev.isEmpty else { return nil }
        let window = Double(now - prevNs)
        var cpuRows: [(pid: pid_t, pct: Double, start: UInt64, mem: UInt64)] = []
        var memRows: [(pid: pid_t, start: UInt64, mem: UInt64)] = []
        cpuRows.reserveCapacity(64)
        memRows.reserveCapacity(cur.count)
        for (pid, s) in cur {
            memRows.append((pid, s.start, s.footprint))
            guard let p = prev[pid], p.start == s.start, s.cpuTicks >= p.cpuTicks else { continue }
            let pct = Double(s.cpuTicks - p.cpuTicks) * ticksToNs / window * 100
            if pct >= 0.05 { cpuRows.append((pid, pct, s.start, s.footprint)) }
        }
        cpuRows.sort { $0.pct > $1.pct }
        memRows.sort { $0.mem > $1.mem }
        let byCPU = cpuRows.prefix(limit).map { r -> ProcessUsage in
            let n = name(r.pid, start: r.start)
            return ProcessUsage(id: r.pid, name: n.name, cpuPercent: r.pct, memoryBytes: r.mem, bundleIdentifier: n.bundle)
        }
        // Memory is ranked by app: what someone wants to know when memory
        // runs short is which app to quit, and Chrome or Claude is dozens of
        // helper processes. The row keeps the app's biggest process as its id.
        var apps: [String: ProcessUsage] = [:]
        for r in memRows {
            let n = name(r.pid, start: r.start)
            var pct = 0.0
            if let p = prev[r.pid], p.start == r.start, let c = cur[r.pid], c.cpuTicks >= p.cpuTicks {
                pct = Double(c.cpuTicks - p.cpuTicks) * ticksToNs / window * 100
            }
            if var row = apps[n.app] {
                row.memoryBytes += r.mem
                row.cpuPercent += pct
                row.processCount += 1
                if row.bundleIdentifier == nil { row.bundleIdentifier = n.bundle }
                apps[n.app] = row
            } else {
                apps[n.app] = ProcessUsage(id: r.pid, name: n.app, cpuPercent: pct, memoryBytes: r.mem,
                                           bundleIdentifier: n.bundle)
            }
        }
        let byMemory = Array(apps.values.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(limit))
        return ProcessRanking(byCPU: byCPU, byMemory: byMemory)
    }

    /// App name and bundle id for GUI apps, executable name otherwise. Cached per
    /// (pid, start time) so a reused pid never inherits the old name.
    private func name(_ pid: pid_t, start: UInt64) -> Name {
        if let n = names[pid], n.start == start { return n }
        var result = Name(start: start, name: "pid \(pid)", bundle: nil, app: "")
        var regularApp = false
        if let app = NSRunningApplication(processIdentifier: pid) {
            result.bundle = app.bundleIdentifier
            if let n = app.localizedName, !n.isEmpty { result.name = n }
            regularApp = app.activationPolicy == .regular
        }
        if regularApp { result.app = result.name }
        if !regularApp || result.bundle == nil || result.name.hasPrefix("pid ") {
            var path = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
                let full = String(cString: path)
                if result.name.hasPrefix("pid ") { result.name = (full as NSString).lastPathComponent }
                if !regularApp, let bundle = full.split(separator: "/").first(where: { $0.hasSuffix(".app") }) {
                    result.app = String(bundle.dropLast(4))
                }
            } else {
                var short = [CChar](repeating: 0, count: 256)
                if proc_name(pid, &short, UInt32(short.count)) > 0, result.name.hasPrefix("pid ") {
                    result.name = String(cString: short)
                }
            }
        }
        if result.app.isEmpty { result.app = result.name }
        names[pid] = result
        return result
    }
}

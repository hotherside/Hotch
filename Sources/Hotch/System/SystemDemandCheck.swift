import Foundation

/// Demand-policy regressions without creating readers, windows, or timers.
/// These scenarios model several visible surfaces opening and closing, which
/// is where a single winning demand can accidentally lose another capability.
enum SystemDemandCheck {
    static func runBlockingAndExit() -> Never {
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print("  \(passed ? "ok  " : "FAIL")  \(name)")
            if !passed { failures += 1 }
        }
        func resolve(_ demands: [SystemDemand], advanced: Bool = true) -> SystemSamplerConfig {
            SystemSamplerConfig.resolved(demands: demands, advanced: advanced)
        }

        let idle = resolve([])
        check("no visible clients stop the sampler", idle.level == 0 && idle.demand == .idle)
        check("idle never requests process enumeration", !idle.processRanking)
        let menu = resolve([.menuBar])
        check("menu bar keeps its lightweight sampling", menu.level == 1 && !menu.processRanking)
        let panel = resolve([.menuBar, .panel])
        check("ordinary cards retain live panel readings and histories", panel.level == 2)
        check("ordinary cards do not enumerate processes", !panel.processRanking)

        for kind in SystemDetailKind.allCases {
            let config = resolve([.panel, .detail(kind)])
            let needsProcesses = kind == .cpu || kind == .memory
            check("\(kind.rawValue) detail requests processes only when displayed",
                  config.processRanking == needsProcesses)
            check("\(kind.rawValue) detail preserves panel history sampling", config.level == 2)
        }

        var clients: [String: SystemDemand] = ["card": .panel, "rail": .menuBar]
        clients["detail"] = .detail(.cpu)
        var config = resolve(Array(clients.values))
        check("entering CPU detail enables its process list", config.processRanking && config.cpuDetail)
        clients["detail"] = .detail(.memory)
        config = resolve(Array(clients.values))
        check("CPU to memory keeps rankings while ending CPU frequency demand",
              config.processRanking && !config.cpuDetail)
        clients.removeValue(forKey: "detail")
        config = resolve(Array(clients.values))
        check("leaving detail ends rankings while the card remains live",
              !config.processRanking && config.level == 2)

        clients["overview"] = .processes
        config = resolve(Array(clients.values))
        check("Mac overview explicitly enables Busiest", config.processRanking && config.level == 2)
        clients["detail"] = .detail(.gpu)
        config = resolve(Array(clients.values))
        check("another surface's GPU detail cannot hide a visible Busiest list",
              config.processRanking && config.demand == .detail(.gpu))
        clients.removeValue(forKey: "overview")
        config = resolve(Array(clients.values))
        check("closing the last list ends rankings even with GPU detail open", !config.processRanking)
        clients.removeValue(forKey: "detail")
        clients.removeValue(forKey: "card")
        config = resolve(Array(clients.values))
        check("closing the card returns to menu bar sampling", config.level == 1 && !config.processRanking)

        let concurrent: [SystemDemand] = [.panel, .processes, .detail(.network), .detail(.memory), .detail(.cpu)]
        let expected = resolve(concurrent)
        check("multiple detail clients retain every required capability",
              expected.cpuDetail && expected.networkDetail && expected.processRanking)
        check("detail precedence remains deterministic", expected.demand == .detail(.cpu))
        for offset in concurrent.indices {
            let rotated = Array(concurrent[offset...]) + Array(concurrent[..<offset])
            check("request order \(offset) cannot change the configuration", resolve(rotated) == expected)
        }
        check("overview and panel precedence is independent of request order",
              resolve([.panel, .processes]) == resolve([.processes, .panel]))
        let basic = resolve([.detail(.cpu)], advanced: false)
        check("disabling advanced sensors does not disable the CPU process list",
              !basic.advanced && basic.processRanking && basic.level == 2)
        print("System demand checks: \(failures == 0 ? "passed" : "failed")")
        exit(failures == 0 ? 0 : 1)
    }
}

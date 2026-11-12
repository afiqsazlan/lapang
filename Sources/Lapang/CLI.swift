import Foundation

// `lapang <command>`: the panel as text or JSON, plus its actions, for terminals and for
// agents (e.g. a Claude Code session driven from your phone). Actions are dry runs that print
// what they would do unless --yes is given, so an agent can show you first and then confirm.

enum CLI {
    static let commands: Set<String> = ["status", "clean", "kill-old-mcp", "quit", "help", "--help"]

    /// Runs a command and exits when the binary was started with one; otherwise returns and the app starts.
    static func runIfRequested() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first, commands.contains(cmd) else { return }
        let rest = Array(args.dropFirst())
        let code: Int32
        switch cmd {
        case "status": code = status(json: rest.contains("--json"))
        case "clean": code = clean(rest)
        case "kill-old-mcp": code = killOldMCP(yes: rest.contains("--yes"))
        case "quit": code = quit(rest)
        default: code = help()
        }
        exit(code)
    }

    static func snapshot() -> Snapshot { Engine.snapshot(sectionsFrom: []) }

    // MARK: status

    static func status(json: Bool) -> Int32 {
        let s = snapshot()
        if json {
            let data = try! JSONSerialization.data(withJSONObject: jsonObject(s), options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return 0
        }
        var out: [String] = []
        out.append(String(format: "Disk     %.0f GB free of %.0f GB · %@", s.freeGB, s.totalGB, trendText(s)))
        let pressure = ["Normal", "Normal", "Under pressure", "Under pressure", "Critical"][min(max(s.pressure, 0), 4)]
        var mem = "Memory   \(pressure)"
        if let share = MemoryHistory.pressuredShare(s.memHistory) {
            mem += " (\(Int((share * 100).rounded()))% of \(windowText(s.memHistory.first?.t)))"
        }
        mem += String(format: " · %.1f of %.0f GB used · swap %@ of %@", Double(s.memUsed) / 1_073_741_824,
                      Double(s.memTotal) / 1_073_741_824, human(bytes: Int64(s.swapUsed)), human(bytes: Int64(s.swapTotal)))
        out.append(mem)

        let chores = s.chores
        out.append("")
        if chores.isEmpty {
            out.append("Nothing to clean.")
        } else {
            let total = chores.reduce(Int64(0)) { $0 + $1.kb }
            out.append("Things to clean (\(chores.count)\(total > 0 ? ", \(human(kb: total)) of disk" : "")). Run `lapang clean` to review:")
            for c in chores { out.append("  - \(c.title): \(c.subtitle)") }
        }

        if !s.memUsers.isEmpty {
            out.append("")
            out.append("Memory users: " + s.memUsers.prefix(6).map { "\($0.name) \(human(bytes: Int64($0.bytes)))" }.joined(separator: " · "))
        }
        let mcp = s.procs.filter { $0.kind == "mcp" }
        if !s.procs.isEmpty {
            let total = s.procs.reduce(UInt64(0)) { $0 + $1.rssBytes }
            var line = "Dev processes: \(s.procs.count) · \(human(bytes: Int64(total)))"
            if mcp.count > 1 {
                line += " · \(mcp.count) MCP servers; `lapang kill-old-mcp` frees \(human(bytes: Int64(oldMCPBytes(s))))"
            }
            out.append(line)
        }
        if let sims = s.sims, !sims.isEmpty {
            out.append("Simulators:")
            for sim in sims {
                out.append("  - \(sim.name): \(sim.usage.summary ?? "no app of yours running")\(sim.usage.projectGone ? " (project deleted)" : "")")
            }
        }
        let caches = s.caches.reduce(Int64(0)) { $0 + ($1.sizeKB ?? 0) }
        out.append("Caches: Xcode \(human(kb: s.derivedTotalKB)) (\(s.derived.count) projects) · packages \(human(kb: caches))"
            + (s.sizesMeasuredAt.map { " · measured \(relative($0))" } ?? ""))
        if let g = s.growth, !g.items.isEmpty {
            out.append("Grew since \(relative(g.since)): " + g.items.prefix(4).map {
                "\($0.name) \($0.deltaKB > 0 ? "+" : "−")\(human(kb: abs($0.deltaKB)))"
            }.joined(separator: " · "))
        }
        for sec in s.sections {
            var line = "\(sec.config.title): "
            if let e = sec.error {
                line += "error: \(e)"
            } else if let o = sec.output {
                let rows = o.rows.filter { $0.group == nil }.map { r in r.subtitle.map { "\(r.title) → \($0)" } ?? r.title }
                line += ([o.badge?.text].compactMap { $0 } + rows).joined(separator: " · ")
            }
            out.append(line)
        }
        print(out.joined(separator: "\n"))
        return 0
    }

    static func trendText(_ s: Snapshot) -> String {
        let t = s.trend
        switch t.state {
        case .learning: return "learning the fill rate"
        case .steady: return "steady"
        case .freeing: return String(format: "freeing %.1f GB/day", t.ratePerDay)
        case .filling:
            var line = String(format: "filling %.1f GB/day", -t.ratePerDay)
            if let h = t.hoursToWarn, h > 0 {
                line += " · \(Int(s.config.disk.warnGB)) GB left in \(durationText(hours: h))"
            } else if let h = t.hoursToFull {
                line += " · full in \(durationText(hours: h))"
            }
            return line
        }
    }

    static func windowText(_ first: Date?) -> String {
        guard let first else { return "the last 24 h" }
        let hours = Date().timeIntervalSince(first) / 3600
        return hours >= 20 ? "the last 24 h" : (hours >= 1 ? "the last \(Int(hours)) h" : "the last \(Int(hours * 60)) min")
    }

    static func relative(_ d: Date) -> String {
        d.formatted(.relative(presentation: .named))
    }

    static func jsonObject(_ s: Snapshot) -> [String: Any] {
        func opt(_ v: Any?) -> Any { v ?? NSNull() }
        return [
            "disk": [
                "freeGB": (s.freeGB * 10).rounded() / 10, "totalGB": s.totalGB.rounded(),
                "level": "\(s.diskLevel)", "trend": "\(s.trend.state)",
                "ratePerDayGB": (s.trend.ratePerDay * 10).rounded() / 10,
                "hoursToWarn": opt(s.trend.hoursToWarn.map { $0.rounded() }), "warnGB": s.config.disk.warnGB,
            ],
            "memory": [
                "pressure": "\(s.pressureLevel)", "usedGB": Double(s.memUsed) / 1_073_741_824,
                "totalGB": Double(s.memTotal) / 1_073_741_824,
                "swapUsedGB": Double(s.swapUsed) / 1_073_741_824, "swapTotalGB": Double(s.swapTotal) / 1_073_741_824,
                "pressuredShare24h": opt(MemoryHistory.pressuredShare(s.memHistory)),
                "users": s.memUsers.map { ["name": $0.name, "bytes": $0.bytes, "processes": $0.processes] },
            ],
            "chores": s.chores.map { ["title": $0.title, "detail": $0.subtitle, "action": $0.button, "diskKB": $0.kb] },
            "simulators": (s.sims ?? []).map { [
                "name": $0.name, "udid": $0.udid, "apps": $0.usage.apps.map(\.name),
                "project": opt($0.usage.project), "projectGone": $0.usage.projectGone,
                "tool": opt($0.usage.tool), "launcher": opt($0.usage.launcher),
            ] },
            "processes": s.procs.map { [
                "pid": $0.pid, "name": $0.name, "kind": $0.kind, "bytes": $0.rssBytes,
                "folder": $0.cwd, "stale": $0.stale, "uptime": $0.uptime,
            ] },
            "xcodeCaches": s.derived.map { [
                "project": $0.title, "status": "\($0.status)", "kb": opt($0.sizeKB), "idleDays": $0.idleDays,
            ] },
            "packageCaches": s.caches.map { ["name": $0.name, "kb": opt($0.sizeKB), "clearable": $0.clearable] },
            "sections": s.sections.map { sec -> [String: Any] in [
                "title": sec.config.title, "error": opt(sec.error), "badge": opt(sec.output?.badge?.text),
                "rows": (sec.output?.rows ?? []).map { ["title": $0.title, "subtitle": opt($0.subtitle), "group": opt($0.group)] },
            ] },
        ]
    }

    // MARK: actions

    /// `lapang clean [--only caches,processes,simulators] [--yes]`
    static func clean(_ args: [String]) -> Int32 {
        let s = snapshot()
        var only: Set<String> = ["caches", "processes", "simulators"]
        if let i = args.firstIndex(of: "--only"), i + 1 < args.count {
            only = Set(args[i + 1].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        }
        let chores = s.chores.filter {
            switch $0.kind {
            case .cache: return only.contains("caches")
            case .process: return only.contains("processes")
            case .simulators: return only.contains("simulators")
            }
        }
        guard !chores.isEmpty else { print("Nothing to clean."); return 0 }
        guard args.contains("--yes") else {
            print("Would clean (run again with --yes to do it):")
            for c in chores { print("  - \(c.button.lowercased()): \(c.title) (\(c.subtitle))") }
            return 0
        }
        for c in chores {
            let result: String?
            switch c.kind {
            case .cache(let e): result = Actions.deleteDerived([e], root: s.derivedDataRoot)
            case .process(let p): result = Actions.kill(p) ?? "Killed \(p.name) (pid \(p.pid))"
            case .simulators(let list): result = list.compactMap { Actions.shutdownSim($0.udid) }.first ?? "Shut down \(list.map(\.name).joined(separator: ", "))"
            }
            print("  - \(c.title): \(result ?? "done")")
        }
        return 0
    }

    static func oldMCPBytes(_ s: Snapshot) -> UInt64 {
        let mcp = s.procs.filter { $0.kind == "mcp" }
        let older = mcp.dropLast()
        return s.procs.filter { p in older.contains { $0.pid == p.pid || $0.pid == p.ppid } }.reduce(0) { $0 + $1.rssBytes }
    }

    /// `lapang kill-old-mcp [--yes]`: every MCP server but the newest, with its children.
    static func killOldMCP(yes: Bool) -> Int32 {
        let s = snapshot()
        let older = Array(s.procs.filter { $0.kind == "mcp" }.dropLast())
        guard !older.isEmpty else { print("At most one MCP server is running; nothing to do."); return 0 }
        let kids = s.procs.filter { p in older.contains { $0.pid == p.ppid } }
        guard yes else {
            print("Would kill \(older.count) MCP server(s) and their language servers, freeing about \(human(bytes: Int64(oldMCPBytes(s)))).")
            print("Those sessions lose their MCP tools until they restart. Run again with --yes to do it.")
            return 0
        }
        print(Actions.killAll(kids + older) ?? "Done")
        return 0
    }

    /// `lapang quit "<app name>" [--yes]`: asks an app from "Memory users" to quit.
    static func quit(_ args: [String]) -> Int32 {
        guard let name = args.first(where: { !$0.hasPrefix("--") }) else {
            print("Usage: lapang quit \"<app name>\" [--yes]")
            return 2
        }
        let s = snapshot()
        guard let u = s.memUsers.first(where: { $0.name.lowercased() == name.lowercased() }), let bundle = u.bundlePath,
              MemoryActions.isQuittable(bundle) else {
            print("No running app named \"\(name)\" in Memory users. Apps: " + s.memUsers.filter { $0.kind == .app }.map(\.name).joined(separator: ", "))
            return 1
        }
        guard args.contains("--yes") else {
            print("Would ask \(u.name) to quit, freeing about \(human(bytes: Int64(u.bytes))). It can still ask to save. Run again with --yes to do it.")
            return 0
        }
        print(MemoryActions.quit(bundlePath: bundle) ?? "Done")
        return 0
    }

    static func help() -> Int32 {
        print("""
        lapang status [--json]       what the menu bar panel shows, as text or JSON
        lapang clean [--only caches,processes,simulators] [--yes]
                                       stale processes, orphaned/unused build caches, simulators
        lapang kill-old-mcp [--yes]  kill every MCP server but the newest (and its language server)
        lapang quit "<app>" [--yes]  ask an app from "Memory users" to quit

        Actions only print what they would do unless --yes is given.
        """)
        return 0
    }
}

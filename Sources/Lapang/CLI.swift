import AppKit
import Foundation

// `lapang <command>`: the panel as text or JSON, plus its actions, for terminals and for
// agents (e.g. a Claude Code session driven from your phone). Actions are dry runs that print
// what they would do unless --yes is given, so an agent can show you first and then confirm.

enum CLI {
    static let commands: Set<String> = ["status", "clean", "kill-old-mcp", "quit", "log", "ports", "stop-port", "share", "report", "mcp", "sims", "help", "--help", "--version", "version"]

    /// Runs a command and exits when the binary was started with one; otherwise returns and the app starts.
    static func runIfRequested() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first, commands.contains(cmd) else { return }
        let rest = Array(args.dropFirst())
        ActionLog.source = "cli"
        let code: Int32
        switch cmd {
        case "status": code = status(json: rest.contains("--json"))
        case "clean": code = clean(rest)
        case "kill-old-mcp": code = rest.contains("--idle") ? killIdleMCP(rest) : killOldMCP(yes: rest.contains("--yes"))
        case "quit": code = quit(rest)
        case "log": code = log(rest)
        case "ports": code = ports(json: rest.contains("--json"))
        case "stop-port": code = stopPort(rest)
        case "share": code = share(rest)
        case "report": code = report(rest)
        case "mcp": code = rest.contains("--config") ? MCPServer.printConfig() : MCPServer.run()
        case "sims": code = sims(rest)
        case "--version", "version": code = version()
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
        if let last = s.memSpikes.last, Date().timeIntervalSince(last.t) <= 86400 {
            out.append("         Last spike \(last.t.formatted(date: .omitted, time: .shortened)) (\(PressureSpikes.label(last))): \(last.summary)")
        }

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
        if !s.ports.isEmpty {
            out.append("Ports: " + s.ports.map { l in
                "\(l.portList) \(l.kind)" + (l.folderGone ? " (folder gone)" : l.folder.map { " (\($0))" } ?? "")
            }.joined(separator: " · "))
        }
        if let sims = s.sims, !sims.isEmpty {
            out.append("Simulators:")
            for sim in sims {
                out.append("  - \(sim.name): \(sim.usage.summary ?? "no app of yours running")\(sim.usage.projectGone ? " (project deleted)" : "")"
                    + (sim.usage.building ? " (don't shut it down)" : ""))
            }
        }
        if let st = s.simStorage {
            out.append("Simulator storage: \(human(bytes: st.totalBytes)) · devices \(human(bytes: st.devicesBytes)) (\(st.devices.count))"
                + " · runtimes \(human(bytes: st.runtimesBytes)) (\(st.runtimes.count)) · dyld cache \(human(kb: st.dyldKB))"
                + (st.unavailable.isEmpty ? "" : " · \(st.unavailable.count) unavailable") + ". `lapang sims` for details")
        }
        let caches = s.caches.reduce(Int64(0)) { $0 + ($1.sizeKB ?? 0) }
        out.append("Caches: Xcode \(human(kb: s.derivedTotalKB)) (\(s.derived.count) projects) · packages \(human(kb: caches))"
            + (s.sizesMeasuredAt.map { " · measured \(relative($0))" } ?? ""))
        if !s.worktrees.isEmpty {
            let total = s.worktrees.reduce(Int64(0)) { $0 + ($1.outputKB ?? 0) }
            let merged = s.worktrees.filter(\.merged)
            out.append("Worktrees: \(s.worktrees.count) · \(human(kb: total)) build output · \(merged.count) merged"
                + (merged.isEmpty ? "" : " (\(human(kb: merged.reduce(0) { $0 + ($1.outputKB ?? 0) })))"))
        }
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
                "spikes": s.memSpikes.suffix(20).reversed().map { sp -> [String: Any] in [
                    "at": ISO8601DateFormatter().string(from: sp.t), "trigger": sp.trigger.rawValue,
                    "swapGB": (sp.swapGB * 10).rounded() / 10, "swapGrowthGB": opt(sp.swapGrowthGB),
                    "comparedWith": opt(sp.since.map { ISO8601DateFormatter().string(from: $0) }),
                    "culprits": sp.culprits.map { ["name": $0.name, "mb": $0.mb, "growthMB": opt($0.growthMB)] },
                ] },
            ],
            "chores": s.chores.map { ["title": $0.title, "detail": $0.subtitle, "action": $0.button, "diskKB": $0.kb] },
            "simulators": (s.sims ?? []).map { [
                "name": $0.name, "udid": $0.udid, "apps": $0.usage.apps.map(\.name),
                "project": opt($0.usage.project), "projectGone": $0.usage.projectGone,
                "tool": opt($0.usage.tool), "launcher": opt($0.usage.launcher), "building": $0.usage.building,
                "toolStartedAt": opt($0.usage.since.map { ISO8601DateFormatter().string(from: $0) }),
                "toolUptimeMinutes": opt($0.usage.since.map { Int(Date().timeIntervalSince($0) / 60) }),
            ] },
            "simulatorStorage": opt(s.simStorage.map(simJSON)),
            "processes": s.procs.map { [
                "pid": $0.pid, "name": $0.name, "kind": $0.kind, "bytes": $0.rssBytes,
                "folder": $0.cwd, "stale": $0.stale, "uptime": $0.uptime,
                "idleHours": opt($0.idleHours.map { ($0 * 10).rounded() / 10 }), "session": opt($0.session),
            ] },
            "ports": s.ports.map(portJSON),
            "xcodeCaches": s.derived.map { [
                "project": $0.title, "status": "\($0.status)", "kb": opt($0.sizeKB), "idleDays": $0.idleDays,
            ] },
            "worktrees": s.worktrees.map { u -> [String: Any] in [
                "path": u.path, "group": u.group, "branches": u.branches, "merged": u.merged, "noCommits": u.noCommits,
                "lastActivity": ISO8601DateFormatter().string(from: u.lastActivity), "idleDays": u.idleDays,
                "outputKB": opt(u.outputKB), "outputs": u.breakdown.map { ["name": $0.name, "kb": $0.kb] },
                "agentOpen": u.agentOpen,
            ] },
            "packageCaches": s.caches.map { ["name": $0.name, "kb": opt($0.sizeKB), "clearable": $0.clearable] },
            "sections": s.sections.map { sec -> [String: Any] in [
                "title": sec.config.title, "error": opt(sec.error), "badge": opt(sec.output?.badge?.text),
                "rows": (sec.output?.rows ?? []).map { ["title": $0.title, "subtitle": opt($0.subtitle), "group": opt($0.group)] },
            ] },
        ]
    }

    // MARK: actions

    /// `lapang clean [--only caches,processes,simulators,worktrees] [--include-building] [--yes]`
    static func clean(_ args: [String]) -> Int32 {
        let s = snapshot()
        let force = args.contains("--include-building")
        var only: Set<String> = ["caches", "processes", "simulators", "ports", "worktrees"]
        if let i = args.firstIndex(of: "--only"), i + 1 < args.count {
            only = Set(args[i + 1].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        }
        let chores = s.chores(includeBuilding: force).filter {
            switch $0.kind {
            case .cache: return only.contains("caches")
            case .process: return only.contains("processes")
            case .simulators: return only.contains("simulators")
            case .port: return only.contains("ports")
            case .worktrees: return only.contains("worktrees")
            case .simUnavailable: return only.contains("simulators")
            case .simRuntime: return false
            }
        }
        let runtimes = s.chores.compactMap { c -> SimRuntime? in if case .simRuntime(let r, _) = c.kind { return r }; return nil }
        let runtimeHint = runtimes.isEmpty ? nil
            : "Unused simulator runtimes (\(runtimes.map { "\($0.name) \(human(bytes: $0.bytes))" }.joined(separator: ", "))) are left to `lapang sims delete-runtime <version>`."
        let busy = (s.sims ?? []).filter(\.usage.building)
        let buildingHint = force || busy.isEmpty || !only.contains("simulators") ? nil
            : "Left running, a build is aimed at \(busy.count == 1 ? "it" : "them"): "
                + busy.map { "\($0.name) (\($0.usage.summary ?? "building"))" }.joined(separator: ", ")
                + ". --include-building shuts \(busy.count == 1 ? "it" : "them") down anyway, which breaks the build."
        defer {
            if let buildingHint { print(buildingHint) }
            if let runtimeHint { print(runtimeHint) }
        }
        guard !chores.isEmpty else { print("Nothing to clean."); return 0 }
        guard args.contains("--yes") else {
            print("Would clean (run again with --yes to do it):")
            for c in chores { print("  - \(c.button.lowercased()): \(c.title) (\(c.subtitle))") }
            return 0
        }
        ActionLog.$batch.withValue("clean") {
            for c in chores {
                let result: String?
                switch c.kind {
                case .cache(let e): result = Actions.deleteDerived([e], root: s.derivedDataRoot)
                case .process(let p): result = Actions.kill(p) ?? "Killed \(p.name) (pid \(p.pid))"
                case .port(let l): result = PortActions.stop(l)
                case .worktrees(let list): result = WorktreeActions.cleanOutput(list)
                case .simulators(let list): result = list.compactMap { Actions.shutdownSim($0, force: force) }.first ?? "Shut down \(list.map(\.name).joined(separator: ", "))"
                case .simUnavailable: result = SimActions.deleteUnavailable()
                case .simRuntime: result = nil
                }
                print("  - \(c.title): \(result ?? "done")")
            }
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
        print(Actions.killAll(kids + older, action: "kill old MCP servers") ?? "Done")
        return 0
    }

    /// `lapang kill-old-mcp --idle [--hours N] [--keep N] [--yes]`: the automatic rule, run by hand.
    /// Defaults to the rule's idleHours and keepNewest from config.json, even while it's turned off.
    static func killIdleMCP(_ args: [String]) -> Int32 {
        let s = snapshot()
        let rule = s.config.processes.mcpCleanup
        func value(_ flag: String) -> Double? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
        }
        let hours = value("--hours") ?? rule.idleHours
        let keep = Int(value("--keep") ?? Double(rule.keepNewest))
        let mcp = s.procs.filter { $0.kind == "mcp" }
        let list = MCPCleanup.candidates(s.procs, idleHours: hours, keepNewest: keep)
        guard !list.isEmpty else {
            print("No MCP server has been idle for \(hoursLabel(hours)) beyond the newest \(keep) (\(mcp.count) running).")
            if let quietest = mcp.compactMap(\.idleHours).max() {
                print("The longest idle has been quiet for \(durationText(hours: quietest)) as far as Lapang has seen.")
            }
            return 0
        }
        let freed = list.reduce(UInt64(0)) { $0 + $1.bytes }
        guard args.contains("--yes") else {
            print("Would stop \(list.count) idle MCP server(s) and their language servers, freeing about \(human(bytes: Int64(freed))):")
            for c in list {
                print("  - pid \(c.server.pid): \(c.server.session ?? "no session found"), idle \(durationText(hours: c.server.idleHours ?? 0)), \(human(bytes: Int64(c.bytes)))")
            }
            print("Those sessions lose their MCP tools until they restart. Run again with --yes to do it.")
            return 0
        }
        let stopped = MCPCleanup.stop(list, auto: false)
        print(MCPCleanup.summary(stopped))
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

    // MARK: log

    /// `lapang log [--json] [--limit N]`: what Lapang did, newest first.
    static func log(_ args: [String]) -> Int32 {
        var limit = 20
        if let i = args.firstIndex(of: "--limit"), i + 1 < args.count {
            guard let n = Int(args[i + 1]), n > 0 else { print("--limit takes a positive number"); return 2 }
            limit = n
        }
        let entries = ActionLog.recent(limit)
        if args.contains("--json") {
            // one object per line, as stored, so it pipes into jq the same way the file does
            for e in entries {
                if let d = try? ActionLog.encoder.encode(e) { print(String(decoding: d, as: UTF8.self)) }
            }
            return 0
        }
        guard !entries.isEmpty else { print("No actions yet. The log is \(Paths.abbreviate(ActionLog.file))."); return 0 }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        for e in entries {
            var line = "\(f.string(from: e.time))  \(e.source.padding(toLength: 5, withPad: " ", startingAt: 0)) \(e.action): \(e.title) · \(e.outcome)"
            if let b = e.batch { line += " [\(b)]" }
            print(line)
            let detail = e.target.sorted { $0.key < $1.key }.map { "\($0.key)=\(Paths.abbreviate($0.value))" }
            print("    " + detail.joined(separator: "  "))
        }
        return 0
    }

    // MARK: report

    /// `lapang report [--out path] [--copy] [--full] [--limit N]`: a diagnostics file for a GitHub issue.
    static func report(_ args: [String]) -> Int32 {
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        var limit = 20
        if let l = value("--limit") {
            guard let n = Int(l), n > 0 else { print("--limit takes a positive number"); return 2 }
            limit = n
        }
        let full = args.contains("--full")
        let o = Report.make(snapshot(), full: full, logLimit: limit)
        let path: String
        do {
            path = try Report.write(o, to: value("--out"))
        } catch {
            print("Couldn't write the report: \(error.localizedDescription)")
            return 1
        }
        print(path)
        print("")
        print("It holds: " + o.contents.joined(separator: " · ") + ".")
        print(full ? "Not redacted (--full): paths, folder names, your user name and host name appear as they are."
            : "Redacted: your user name, host names, and folder names under your home folder (shown as hashes like ‹3fa2c1›). --full keeps them.")
        if args.contains("--copy") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(o.clipboard(file: path), forType: .string)
            print("Copied a Markdown summary to the clipboard.")
        }
        print("Nothing was sent anywhere. Read the file, then attach it to an issue: \(Report.issuesURL)")
        return 0
    }

    // MARK: ports

    static func portJSON(_ l: Listener) -> [String: Any] {
        [
            "ports": l.ports.map(Int.init), "pid": l.pid, "process": l.name, "kind": l.kind,
            "label": l.label ?? NSNull(), "exposure": l.exposure, "folder": l.cwd, "folderGone": l.folderGone,
            "uptime": l.uptime, "startedAt": ISO8601DateFormatter().string(from: l.started), "bytes": l.bytes,
            "url": l.url ?? NSNull(), "stoppable": l.stoppable,
        ]
    }

    /// `lapang ports [--json]`
    static func ports(json: Bool) -> Int32 {
        let (config, _) = Config.load()
        let ls = Ports.discover(config.ports)
        if json {
            let data = try! JSONSerialization.data(withJSONObject: ls.map(portJSON), options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return 0
        }
        guard !ls.isEmpty else {
            print("No servers of yours are listening on ports \(config.ports.minPort)–\(config.ports.maxPort).")
            return 0
        }
        let width = ls.map(\.portList.count).max() ?? 5
        let names = ls.map { "\($0.kind)\($0.label.map { " [\($0)]" } ?? "")" }
        let nameWidth = names.map(\.count).max() ?? 10
        for (l, name) in zip(ls, names) {
            let port = l.portList.padding(toLength: width, withPad: " ", startingAt: 0)
            var line = "\(port)  \(name.padding(toLength: nameWidth, withPad: " ", startingAt: 0))  pid \(String(l.pid).padding(toLength: 6, withPad: " ", startingAt: 0))"
            line += l.subtitle + " · " + l.exposure
            if l.folderGone { line += "  (folder deleted)" }
            print(line)
        }
        return 0
    }

    /// `lapang stop-port <port> [--yes]`: SIGTERM to the process that owns the LISTEN socket on
    /// that port, and nothing else. Programs connected to the port are never touched.
    static func stopPort(_ args: [String]) -> Int32 {
        guard let arg = args.first(where: { !$0.hasPrefix("--") }), let port = UInt16(arg.trimmingCharacters(in: CharacterSet(charactersIn: ":"))) else {
            print("Usage: lapang stop-port <port> [--yes]")
            return 2
        }
        // every listener of yours, ignoring the panel's port range and hide list
        guard let l = Ports.all().first(where: { $0.ports.contains(port) }) else {
            print("Nothing of yours is listening on port \(port). (System services, app helpers and other users' processes aren't counted.)")
            return 1
        }
        if let note = l.stopNote { print("\(l.kind) holds port \(port). \(note)"); return 1 }
        guard args.contains("--yes") else {
            print("Would stop \(l.kind) on port \(port): \(l.name), pid \(l.pid), up \(l.uptime), \(human(bytes: Int64(l.bytes)))"
                + (l.cwd.isEmpty ? "" : ", in \(Paths.abbreviate(l.cwd))") + ".")
            if l.ports.count > 1 { print("It also listens on \(l.ports.filter { $0 != port }.map(String.init).joined(separator: ", ")).") }
            print("Only this process gets SIGTERM. Anything connected to the port (a tunnel, a browser) is left alone.")
            if l.isTunnel { print("This is a tunnel: every URL served through it goes down until you start it again.") }
            print("Run again with --yes to do it.")
            return 0
        }
        var target = l
        target.ports = [port]
        print(PortActions.stop(target))
        return 0
    }

    /// "0.1.0 (1)": the app's version and build number, read from the bundle the binary runs from.
    /// `lapang` is usually a symlink into Lapang.app, which Bundle.main doesn't follow.
    static var versionString: String {
        var bundle = Bundle.main
        if bundle.infoDictionary?["CFBundleShortVersionString"] == nil,
           let exe = bundle.executableURL?.resolvingSymlinksInPath(),
           let app = Bundle(url: exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) {
            bundle = app
        }
        let info = bundle.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "dev"
        return (info["CFBundleVersion"] as? String).map { "\(v) (\($0))" } ?? v
    }

    static func version() -> Int32 {
        print("lapang \(versionString)")
        return 0
    }

    static func help() -> Int32 {
        print("""
        lapang status [--json]       what the menu bar panel shows, as text or JSON
        lapang clean [--only caches,processes,simulators,ports,worktrees] [--include-building] [--yes]
                                       stale processes, orphaned/unused build caches, simulators (not mid-build),
                                       servers from deleted folders, build output of merged, idle worktrees
        lapang kill-old-mcp [--yes]  kill every MCP server but the newest (and its language server)
        lapang kill-old-mcp --idle [--hours N] [--keep N] [--yes]
                                       stop MCP servers with no tool calls for N hours (config's idleHours)
        lapang quit "<app>" [--yes]  ask an app from "Memory users" to quit
        lapang log [--json] [--limit N]
                                       what Lapang did (newest first, last 30 days)
        lapang ports [--json]        your servers listening on a TCP port, with folder and uptime
        lapang stop-port <port> [--yes]
                                       SIGTERM to the process listening on that port (never to
                                       programs merely connected to it)
        lapang share [now|today|week|clean] [--ratio 16:9|1:1|4:5|9:16] [--out file.png] [--copy] [--names]
                                       a shareable PNG card of what this Mac went through; prints its path
        lapang report [--out path] [--copy] [--full] [--limit N]
                                       a diagnostics file to attach to a GitHub issue (Desktop by default;
                                       prints its path). Redacts your user name, host names and folder
                                       names under home unless --full; --copy puts a summary on the
                                       clipboard; --limit sets how many log entries (20). Sends nothing.
        lapang mcp                   an MCP server on stdin/stdout, so Claude can check this Mac and
                                       run these actions (they preview until called with confirm: true)
        lapang mcp --config          the Claude Desktop config entry for this install
        lapang sims [--json] [--all]  disk use per simulator device, runtime and dyld cache
        lapang sims erase <udid|name> [--yes]
                                       reset a shut-down simulator to factory content
        lapang sims delete-unavailable [--yes]
                                       remove simulators whose runtime is gone
        lapang sims delete-runtime <version|id> [--yes]
                                       remove a simulator runtime nothing booted is using
        lapang --version             the installed version and build number

        Actions only print what they would do unless --yes is given.
        """)
        return 0
    }
}

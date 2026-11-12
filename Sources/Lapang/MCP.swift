import Darwin
import Foundation

// `lapang mcp`: a Model Context Protocol server over stdio, so Claude (Claude Desktop, Claude Code)
// can ask how this Mac is doing and run Lapang's cleanups. One JSON-RPC message per line in and out.
//
// The tools that act reuse the CLI commands and keep their safety: without `confirm: true` they only
// describe what they would do. stdout carries the protocol, so everything the CLI code prints is
// captured into the tool result, and any stray print elsewhere goes to stderr instead.

enum MCPServer {
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// The real stdout, kept for protocol messages; fd 1 points at stderr while the server runs.
    nonisolated(unsafe) private static var protocolOut: Int32 = -1

    static func run() -> Int32 {
        ActionLog.source = "mcp"
        fflush(stdout)
        protocolOut = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let msg = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            handle(msg)
        }
        return 0
    }

    static func handle(_ msg: [String: Any]) {
        guard let method = msg["method"] as? String else { return }  // a response to us; we send no requests
        guard let id = msg["id"] else { return }  // notifications: initialized, cancelled
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            reply(id, [
                "protocolVersion": protocolVersions.contains(asked) ? asked : protocolVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "lapang", "title": "Lapang", "version": CLI.versionString],
                "instructions": instructions,
            ])
        case "ping": reply(id, [:])
        case "tools/list": reply(id, ["tools": tools.map(\.json)])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            guard let tool = tools.first(where: { $0.name == name }) else {
                fail(id, -32602, "Unknown tool: \(name)")
                return
            }
            let (text, isError) = tool.run(params["arguments"] as? [String: Any] ?? [:])
            reply(id, ["content": [["type": "text", "text": text]], "isError": isError])
        case "resources/list": reply(id, ["resources": []])
        case "resources/templates/list": reply(id, ["resourceTemplates": []])
        case "prompts/list": reply(id, ["prompts": []])
        default: fail(id, -32601, "Method not found: \(method)")
        }
    }

    static func reply(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func fail(_ id: Any, _ code: Int, _ message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    static func send(_ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = write(protocolOut, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { if errno == EINTR { continue } else { return } }
                off += n
            }
        }
    }

    /// Runs a CLI command and returns what it printed. A temp file rather than a pipe, so a long
    /// output can't fill the pipe and block the command before we read it.
    static func capture(_ body: () -> Int32) -> (String, Int32) {
        let path = NSTemporaryDirectory() + "lapang-mcp-\(getpid()).out"
        let fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return ("Couldn't capture output", 1) }
        defer { close(fd); unlink(path) }
        fflush(stdout)
        dup2(fd, STDOUT_FILENO)
        let code = body()
        fflush(stdout)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), code)
    }

    static func json(_ obj: Any, pretty: Bool = false) -> String {
        let opts: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: opts) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    // MARK: tools

    struct Tool {
        let name: String
        let title: String
        let description: String
        var properties: [String: Any] = [:]
        var required: [String] = []
        /// Changes something on the Mac; previews unless called with confirm: true.
        var acts = false
        let run: ([String: Any]) -> (String, Bool)

        var json: [String: Any] {
            var props = properties
            if acts {
                props["confirm"] = [
                    "type": "boolean", "default": false,
                    "description": "Leave out (or false) to only preview what would happen. Set to true only after the person has seen the preview and said yes.",
                ]
            }
            return [
                "name": name, "title": title, "description": description,
                "inputSchema": ["type": "object", "properties": props, "required": required, "additionalProperties": false],
                "annotations": [
                    "title": title, "readOnlyHint": !acts, "destructiveHint": acts,
                    "idempotentHint": !acts, "openWorldHint": false,
                ],
            ]
        }
    }

    static let instructions = """
    Lapang watches this Mac's free disk space, memory, leftover developer tools and caches. Use the \
    get_ tools to answer questions about how the Mac is doing; start with get_mac_health. Explain \
    results in plain words: many people asking are not developers.

    The tools that change things (clean_up, stop_old_mcp_servers, quit_app, stop_port) only show a \
    preview unless called with confirm: true. Always call them without confirm first, tell the person \
    what would happen in plain words, and call again with confirm: true only after they clearly agree. \
    Every action is recorded in get_recent_actions.
    """

    /// Only a real JSON `true` counts, not 1 or "true".
    static func confirmed(_ args: [String: Any]) -> Bool {
        guard let v = args["confirm"] as? NSNumber, CFGetTypeID(v) == CFBooleanGetTypeID() else { return false }
        return v.boolValue
    }

    /// Runs a CLI action, swapping its "--yes" hint for one that fits a tool call.
    static func action(_ tool: String, _ args: [String: Any], _ body: ([String]) -> Int32, _ cli: [String]) -> (String, Bool) {
        let yes = confirmed(args)
        var (text, code) = capture { body(cli + (yes ? ["--yes"] : [])) }
        let hint = #"\s*\(?[Rr]un again with --yes to do it\.?\)?"#
        let preview = text.range(of: hint, options: .regularExpression) != nil
        text = text.replacingOccurrences(of: hint, with: "", options: .regularExpression)
        if preview {
            text += "\n\nThis was only a preview: nothing was changed. If the person agrees, call \(tool) again with confirm: true."
        }
        return (text.isEmpty ? "Done." : text, code != 0)
    }

    static let tools: [Tool] = [
        Tool(name: "get_mac_health", title: "Check this Mac's health",
             description: """
             Everything Lapang sees on this Mac in one go: free disk space and whether it's filling up, \
             memory pressure and the apps using the most memory, things that are safe to clean up (with \
             how much space each frees), simulators, background developer tools, servers on network ports, \
             and build caches. Start here when someone asks if their Mac is OK, why it's slow, or why it's \
             running out of space. Levels are "ok", "warn" or "crit". Sizes are in KB (kb, diskKB, outputKB) \
             or bytes (bytes) unless the name says GB. Takes several seconds.
             """) { _ in
            (json(health(CLI.snapshot())), false)
        },

        Tool(name: "get_memory", title: "Memory and what's using it",
             description: """
             How hard this Mac's memory is working right now (pressure "ok", "warn" or "crit"), \
             how much swap (memory spilled onto the disk) is in use, how much of the last day was spent \
             under pressure, which apps use the most memory, and recent pressure spikes with the apps that \
             grew when each began (culprits). Use it when the Mac feels slow, apps are beachballing, or \
             someone asks what slowed it down earlier. Apps marked canQuit can be closed with quit_app.
             """) { _ in
            let s = CLI.snapshot()
            var mem = CLI.jsonObject(s)["memory"] as? [String: Any] ?? [:]
            mem["users"] = s.memUsers.map { u -> [String: Any] in [
                "name": u.name, "bytes": u.bytes, "readable": human(bytes: Int64(u.bytes)), "processes": u.processes,
                "kind": "\(u.kind)", "canQuit": u.bundlePath.map(MemoryActions.isQuittable) ?? false,
            ] }
            mem["summary"] = memorySummary(s)
            return (json(mem), false)
        },

        Tool(name: "get_disk", title: "Disk space, growth and forecast",
             description: """
             Free disk space, how fast it has been filling or freeing up, and when it will run low if \
             nothing changes. Also what grew since the last day's measurement, and the things Lapang can \
             clean up with how much space each would free. Use it when someone is running out of space or \
             asks what is eating their disk.
             """) { _ in
            let s = CLI.snapshot()
            let all = CLI.jsonObject(s)
            var out: [String: Any] = ["disk": all["disk"] ?? [:], "summary": "Disk: " + String(format: "%.0f GB free of %.0f GB · ", s.freeGB, s.totalGB) + CLI.trendText(s)]
            if let g = s.growth {
                out["growth"] = [
                    "since": ISO8601DateFormatter().string(from: g.since),
                    "items": g.items.map { i -> [String: Any] in
                        let sign = i.deltaKB < 0 ? "-" : "+"
                        return ["name": i.name, "deltaKB": i.deltaKB, "readable": sign + human(kb: abs(i.deltaKB)), "detail": i.detail ?? NSNull()]
                    },
                    "untrackedKB": g.untrackedKB ?? NSNull(),
                ] as [String: Any]
            }
            out["cleanable"] = s.chores.map { ["title": $0.title, "detail": $0.subtitle, "diskKB": $0.kb, "readable": human(kb: $0.kb)] }
            out["xcodeCachesKB"] = s.derivedTotalKB
            out["packageCaches"] = all["packageCaches"]
            return (json(out), false)
        },

        Tool(name: "list_simulators", title: "Running simulators",
             description: """
             The iPhone, iPad and other simulators that are switched on, which of your apps each is running, \
             and whether the project behind it still exists. Running simulators use a lot of memory; \
             clean_up can shut down ones nobody is using.
             """) { _ in
            let s = CLI.snapshot()
            guard s.sims != nil else { return ("Xcode's simulator tools aren't installed on this Mac.", false) }
            return (json(CLI.jsonObject(s)["simulators"] ?? []), false)
        },

        Tool(name: "list_ports", title: "Servers on network ports",
             description: """
             Programs of yours that are listening on a network port (development servers, databases, \
             tunnels), with the port number, the folder they run from, how long they've been up, and \
             whether the folder has since been deleted. stop_port can stop one.
             """) { _ in
            let (config, _) = Config.load()
            return (json(Ports.discover(config.ports).map(CLI.portJSON)), false)
        },

        Tool(name: "get_recent_actions", title: "What Lapang did recently",
             description: """
             The log of what Lapang cleaned, stopped or shut down, newest first, with what each freed and \
             whether it came from the menu bar, the lapang command or Claude (source "mcp"). Kept 30 days.
             """,
             properties: ["limit": ["type": "integer", "minimum": 1, "maximum": 200, "default": 20, "description": "How many entries to return."]]) { args in
            let limit = min(max((args["limit"] as? Int) ?? 20, 1), 200)
            let entries = ActionLog.recent(limit).compactMap { e in
                (try? ActionLog.encoder.encode(e)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            }
            return (entries.isEmpty ? "Lapang hasn't done anything yet." : json(entries), false)
        },

        Tool(name: "clean_up", title: "Clean up leftovers",
             description: """
             Frees disk space and memory by removing what Lapang lists as safe to clean: Xcode build caches \
             of deleted or long-unused projects, developer tools left running after their window closed, \
             simulators nobody is using, servers running from deleted folders, and build output of finished \
             work. It never touches documents, photos or app data. Without confirm it only lists what it \
             would do. Show that list to the person and ask before calling again with confirm: true.
             """,
             properties: ["only": [
                "type": "array", "items": ["type": "string", "enum": ["caches", "processes", "simulators", "ports", "worktrees"]],
                "description": "Limit the cleanup to some kinds. Leave out to include everything.",
             ]],
             acts: true) { args in
            let kinds = (args["only"] as? [String]) ?? []
            return action("clean_up", args, CLI.clean, kinds.isEmpty ? [] : ["--only", kinds.joined(separator: ",")])
        },

        Tool(name: "stop_old_mcp_servers", title: "Stop old AI helper servers",
             description: """
             AI coding tools such as Claude Code start small helper programs ("MCP servers"), and old ones \
             can keep running and using memory after their session is over. This stops all but the newest, \
             or with idle_hours, only those with no activity for that long. Any open session that used a \
             stopped helper loses those tools until it restarts. Without confirm it only previews.
             """,
             properties: [
                "idle_hours": ["type": "number", "minimum": 0, "description": "Only stop helpers idle at least this many hours. Leave out to stop every helper but the newest."],
                "keep_newest": ["type": "integer", "minimum": 0, "description": "With idle_hours: always keep this many of the newest helpers."],
             ],
             acts: true) { args in
            guard let hours = args["idle_hours"] as? Double else {
                return action("stop_old_mcp_servers", args, { CLI.killOldMCP(yes: $0.contains("--yes")) }, [])
            }
            var cli = ["--idle", "--hours", String(hours)]
            if let keep = args["keep_newest"] as? Int { cli += ["--keep", String(keep)] }
            return action("stop_old_mcp_servers", args, CLI.killIdleMCP, cli)
        },

        Tool(name: "quit_app", title: "Quit an app",
             description: """
             Asks an app to quit to free memory, the same as choosing Quit in its menu: it can still ask to \
             save unsaved work. Use a name from get_memory where canQuit is true. Without confirm it only \
             says how much memory quitting would free.
             """,
             properties: ["app": ["type": "string", "description": "The app's name exactly as get_memory lists it, e.g. \"Google Chrome\"."]],
             required: ["app"], acts: true) { args in
            guard let app = args["app"] as? String, !app.isEmpty else { return ("Say which app to quit.", true) }
            return action("quit_app", args, CLI.quit, [app])
        },

        Tool(name: "stop_port", title: "Stop a server on a port",
             description: """
             Stops the program listening on a network port (for example a development server left running), \
             by politely asking it to shut down. Only that one program is stopped; browsers or apps connected \
             to it are left alone. Without confirm it only says what is running there.
             """,
             properties: ["port": ["type": "integer", "minimum": 1, "maximum": 65535, "description": "The port number, e.g. 3000."]],
             required: ["port"], acts: true) { args in
            guard let port = args["port"] as? Int, (1...65535).contains(port) else { return ("Give a port number between 1 and 65535.", true) }
            return action("stop_port", args, CLI.stopPort, [String(port)])
        },
    ]

    /// `status --json`, with the worktree list (one entry per checkout, often 100+) cut to a summary and
    /// the largest few, so the whole answer stays a few thousand tokens.
    static func health(_ s: Snapshot) -> [String: Any] {
        var out = CLI.jsonObject(s)
        let units = s.worktrees
        let merged = units.filter(\.merged)
        let kb = { (list: [WorktreeUnit]) in list.reduce(Int64(0)) { $0 + ($1.outputKB ?? 0) } }
        out["worktrees"] = [
            "count": units.count, "outputKB": kb(units), "merged": merged.count, "mergedOutputKB": kb(merged),
            "largest": units.filter { ($0.outputKB ?? 0) > 0 }.sorted { ($0.outputKB ?? 0) > ($1.outputKB ?? 0) }.prefix(10).map { u -> [String: Any] in
                ["path": u.path, "branches": u.branches, "merged": u.merged, "idleDays": u.idleDays, "outputKB": u.outputKB ?? 0]
            },
        ] as [String: Any]
        out["summary"] = "Disk: " + String(format: "%.0f GB free of %.0f GB, ", s.freeGB, s.totalGB) + CLI.trendText(s)
            + ". " + memorySummary(s) + (s.chores.isEmpty ? " Nothing to clean." : " \(s.chores.count) things to clean up.")
        return out
    }

    static func memorySummary(_ s: Snapshot) -> String {
        let pressure = ["normal", "normal", "under pressure", "under pressure", "critical"][min(max(s.pressure, 0), 4)]
        var line = "Memory is \(pressure)"
        if let share = MemoryHistory.pressuredShare(s.memHistory) {
            line += " (under pressure \(Int((share * 100).rounded()))% of \(CLI.windowText(s.memHistory.first?.t)))"
        }
        return line + String(format: ", %.1f of %.0f GB used, swap %@.", Double(s.memUsed) / 1_073_741_824,
                             Double(s.memTotal) / 1_073_741_824, human(bytes: Int64(s.swapUsed)))
    }

    // MARK: setup snippets, for the README and the gear menu

    /// The path Claude should launch: the Homebrew link when it points at this app, else this binary.
    static var commandPath: String {
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
        for link in ["/opt/homebrew/bin/lapang", "/usr/local/bin/lapang"] {
            if URL(fileURLWithPath: link).resolvingSymlinksInPath().path == exe { return link }
        }
        return exe
    }

    static var desktopConfig: String {
        json(["mcpServers": ["lapang": ["command": commandPath, "args": ["mcp"]]]], pretty: true)
    }

    static var claudeCodeCommand: String { "claude mcp add lapang -- \(commandPath) mcp" }

    static func printConfig() -> Int32 {
        print(desktopConfig)
        return 0
    }
}

import Foundation

/// `~/.config/lapang/config.json`. Every key is optional; anything missing uses the default.
/// Re-read on every refresh, so edits apply within a minute without restarting.
struct Config: Decodable {
    var refreshSeconds = 60
    var disk = Disk()
    var xcode = Xcode()
    var processes = Processes()
    var caches = Caches()
    var ports = Ports()
    var worktrees = Worktrees()
    var sections: [SectionConfig] = []
    var share = Share()

    struct Share: Decodable {
        /// A notification on Monday mornings with last week's recap, ready to share.
        var weeklyRecap = false

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            weeklyRecap = try c.decodeIfPresent(Bool.self, forKey: .weeklyRecap) ?? weeklyRecap
        }
        enum CodingKeys: String, CodingKey { case weeklyRecap }
    }

    struct Disk: Decodable {
        /// Below this much free space the menu bar turns to a warning and a notification fires.
        var warnGB = 20.0
        var criticalGB = 10.0
        var notify = true
        /// Warn early when, at the current fill rate, free space reaches warnGB within this many hours.
        var forecastHours = 24.0
        /// Extra folders to measure for "what's growing" (package caches and Xcode are always measured).
        var watch: [String] = []

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            warnGB = try c.decodeIfPresent(Double.self, forKey: .warnGB) ?? warnGB
            criticalGB = try c.decodeIfPresent(Double.self, forKey: .criticalGB) ?? criticalGB
            notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? notify
            forecastHours = try c.decodeIfPresent(Double.self, forKey: .forecastHours) ?? forecastHours
            watch = try c.decodeIfPresent([String].self, forKey: .watch) ?? watch
        }
        enum CodingKeys: String, CodingKey { case warnGB, criticalGB, notify, forecastHours, watch }
    }

    struct Xcode: Decodable {
        /// Build caches of projects not built for this many days count as unused.
        var idleDays = 3
        /// Project folders whose build caches are never cleaned in bulk (e.g. your main checkouts).
        var protect: [String] = []

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            idleDays = try c.decodeIfPresent(Int.self, forKey: .idleDays) ?? idleDays
            protect = try c.decodeIfPresent([String].self, forKey: .protect) ?? protect
        }
        enum CodingKeys: String, CodingKey { case idleDays, protect }
    }

    struct Processes: Decodable {
        /// Executable names to watch. A watched process is stale when its parent died or its folder is gone.
        var names = ["dart", "dartvm", "dartaotruntime"]
        var mcpCleanup = MCPCleanupRule()

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            names = try c.decodeIfPresent([String].self, forKey: .names) ?? names
            mcpCleanup = try c.decodeIfPresent(MCPCleanupRule.self, forKey: .mcpCleanup) ?? mcpCleanup
        }
        enum CodingKeys: String, CodingKey { case names, mcpCleanup }
    }

    /// Stop MCP servers that have been idle this long, keeping the newest few. Off until you turn it on.
    struct MCPCleanupRule: Decodable {
        var enabled = false
        var idleHours = 2.0
        var keepNewest = 1

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
            idleHours = try c.decodeIfPresent(Double.self, forKey: .idleHours) ?? idleHours
            keepNewest = try c.decodeIfPresent(Int.self, forKey: .keepNewest) ?? keepNewest
        }
        enum CodingKeys: String, CodingKey { case enabled, idleHours, keepNewest }
    }

    struct Worktrees: Decodable {
        /// Repositories whose linked worktrees are listed (the main checkout itself isn't).
        var repos: [WorktreeSource] = []
        /// Folders whose every subfolder is one unit holding worktrees of several repositories.
        var roots: [WorktreeSource] = []
        /// How to remove one. {repo}, {path} and {name} (the folder name) are filled in, shell-quoted.
        var removeCommand = "git -C {repo} worktree remove {path}"
        /// Merged worktrees untouched for this many days show up under things to clean.
        var idleDays = 3

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            repos = try c.decodeIfPresent([WorktreeSource].self, forKey: .repos) ?? repos
            roots = try c.decodeIfPresent([WorktreeSource].self, forKey: .roots) ?? roots
            removeCommand = try c.decodeIfPresent(String.self, forKey: .removeCommand) ?? removeCommand
            idleDays = try c.decodeIfPresent(Int.self, forKey: .idleDays) ?? idleDays
        }
        enum CodingKeys: String, CodingKey { case repos, roots, removeCommand, idleDays }
    }

    /// A repo or root: a path, or { "path", "title", "removeCommand", "base" }.
    struct WorktreeSource: Decodable, Hashable {
        var path: String
        var title: String?
        var removeCommand: String?
        /// What "merged" is checked against; the remote's default branch (origin/HEAD) when unset.
        var base: String?

        init(from d: Decoder) throws {
            if let p = try? d.singleValueContainer().decode(String.self) {
                path = p
                return
            }
            let c = try d.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            removeCommand = try c.decodeIfPresent(String.self, forKey: .removeCommand)
            base = try c.decodeIfPresent(String.self, forKey: .base)
        }
        enum CodingKeys: String, CodingKey { case path, title, removeCommand, base }
    }

    struct Caches: Decodable {
        /// Cache ids to leave out of the panel (npm, yarn, pnpm, cocoapods, gradle, pub, homebrew, archives, devicesupport).
        var hide: [String] = []

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            hide = try c.decodeIfPresent([String].self, forKey: .hide) ?? hide
        }
        enum CodingKeys: String, CodingKey { case hide }
    }

    struct Ports: Decodable {
        /// Ports outside this range are left out; 49152 and up is the range the system hands out
        /// for temporary ports (debugger and editor helpers), not servers you started.
        var minPort = 1024
        var maxPort = 49151
        /// Port numbers, or process names / kinds ("adb", "cloudflared", "Vite"), to leave out.
        var hide: [Hide] = []
        /// Your own names for ports, e.g. {"3000": "tunnel origin"}.
        var names: [String: String] = [:]

        enum Hide: Decodable {
            case port(Int)
            case name(String)

            init(from d: Decoder) throws {
                let c = try d.singleValueContainer()
                if let p = try? c.decode(Int.self) { self = .port(p) } else { self = .name(try c.decode(String.self)) }
            }

            func matches(port p: UInt16) -> Bool {
                if case .port(let n) = self { return n == Int(p) }
                return false
            }

            func matches(listener l: Listener) -> Bool {
                guard case .name(let n) = self else { return false }
                return [l.name, l.kind].contains { $0.caseInsensitiveCompare(n) == .orderedSame }
            }
        }

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            minPort = try c.decodeIfPresent(Int.self, forKey: .minPort) ?? minPort
            maxPort = try c.decodeIfPresent(Int.self, forKey: .maxPort) ?? maxPort
            hide = try c.decodeIfPresent([Hide].self, forKey: .hide) ?? hide
            names = try c.decodeIfPresent([String: String].self, forKey: .names) ?? names
        }
        enum CodingKeys: String, CodingKey { case minPort, maxPort, hide, names }
    }

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        refreshSeconds = try c.decodeIfPresent(Int.self, forKey: .refreshSeconds) ?? refreshSeconds
        disk = try c.decodeIfPresent(Disk.self, forKey: .disk) ?? disk
        xcode = try c.decodeIfPresent(Xcode.self, forKey: .xcode) ?? xcode
        processes = try c.decodeIfPresent(Processes.self, forKey: .processes) ?? processes
        caches = try c.decodeIfPresent(Caches.self, forKey: .caches) ?? caches
        ports = try c.decodeIfPresent(Ports.self, forKey: .ports) ?? ports
        worktrees = try c.decodeIfPresent(Worktrees.self, forKey: .worktrees) ?? worktrees
        sections = try c.decodeIfPresent([SectionConfig].self, forKey: .sections) ?? sections
        share = try c.decodeIfPresent(Share.self, forKey: .share) ?? share
    }
    enum CodingKeys: String, CodingKey { case refreshSeconds, disk, xcode, processes, caches, ports, worktrees, sections, share }

    static let directory = Paths.home + "/.config/lapang"
    static let path = directory + "/config.json"

    /// Returns the config and, when the file exists but can't be read, why.
    static func load() -> (Config, String?) {
        guard let data = FileManager.default.contents(atPath: path) else { return (Config(), nil) }
        do {
            return (try JSONDecoder().decode(Config.self, from: data), nil)
        } catch {
            return (Config(), "config.json: \(error.localizedDescription)")
        }
    }

    static let starter = """
    {
      "refreshSeconds": 60,
      "disk": { "warnGB": 20, "criticalGB": 10, "notify": true, "forecastHours": 24, "watch": [] },
      "xcode": { "idleDays": 3, "protect": [] },
      "processes": {
        "names": ["dart", "dartvm", "dartaotruntime"],
        "mcpCleanup": { "enabled": false, "idleHours": 2, "keepNewest": 1 }
      },
      "caches": { "hide": [] },
      "ports": { "minPort": 1024, "maxPort": 49151, "hide": [], "names": {} },
      "worktrees": { "repos": [], "roots": [], "removeCommand": "git -C {repo} worktree remove {path}" },
      "share": { "weeklyRecap": false },
      "sections": []
    }

    """

    /// Creates the starter config if there is none, and returns its path.
    static func ensureFile() -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: Data(starter.utf8))
        }
        return path
    }

    /// Turns the MCP cleanup rule on or off by editing just that value, keeping the rest of the
    /// file (its layout, other keys) as you wrote it. Returns why it couldn't, if it couldn't.
    static func setMCPCleanup(_ on: Bool) -> String? {
        let current = String(decoding: FileManager.default.contents(atPath: ensureFile()) ?? Data(), as: UTF8.self)
        guard let text = settingMCPCleanup(on, in: current) else {
            return "Couldn't update config.json safely; edit processes.mcpCleanup.enabled by hand"
        }
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "Couldn't save config.json: \(error.localizedDescription)"
        }
    }

    /// The config text with processes.mcpCleanup.enabled set, or nil when that can't be done safely.
    static func settingMCPCleanup(_ on: Bool, in original: String) -> String? {
        var text = original
        let value = on ? "true" : "false"
        func firstMatch(_ pattern: String, in t: String) -> Range<String.Index>? {
            t.range(of: pattern, options: .regularExpression)
        }
        if let block = firstMatch(#""mcpCleanup"\s*:\s*\{[^{}]*\}"#, in: text) {
            var b = String(text[block])
            if let e = firstMatch(#""enabled"\s*:\s*(true|false)"#, in: b) {
                b.replaceSubrange(e, with: "\"enabled\": \(value)")
            } else if let brace = b.firstIndex(of: "{") {
                let empty = b.dropFirst().dropLast().allSatisfy(\.isWhitespace)
                b.insert(contentsOf: " \"enabled\": \(value)" + (empty ? " " : ","), at: b.index(after: brace))
            }
            text.replaceSubrange(block, with: b)
        } else if let p = firstMatch(#""processes"\s*:\s*\{"#, in: text) {
            let rest = text[p.upperBound...].drop { $0 == " " || $0 == "\n" }
            let comma = rest.first == "}" ? "" : ","
            text.insert(contentsOf: " \"mcpCleanup\": { \"enabled\": \(value) }\(comma)", at: p.upperBound)
        } else if let brace = text.firstIndex(of: "{") {
            let rest = text[text.index(after: brace)...].drop { $0 == " " || $0 == "\n" }
            let comma = rest.first == "}" ? "" : ","
            text.insert(contentsOf: "\n  \"processes\": { \"mcpCleanup\": { \"enabled\": \(value) } }\(comma)",
                        at: text.index(after: brace))
        } else {
            return nil
        }
        guard (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil else { return nil }
        return text
    }
}

/// A custom section: an executable that prints JSON (see README, "Custom sections").
struct SectionConfig: Decodable, Identifiable, Hashable {
    let title: String
    let icon: String?
    let command: String
    var id: String { title }
}

enum Paths {
    /// LAPANG_HOME points Lapang at another home folder (config, data, ~ in paths), for trying
    /// actions on throwaway targets.
    static let home = ProcessInfo.processInfo.environment["LAPANG_HOME"] ?? NSHomeDirectory()

    static func expand(_ p: String) -> String {
        if p == "~" { return home }
        if p.hasPrefix("~/") { return home + p.dropFirst(1) }
        return p
    }

    static func abbreviate(_ p: String) -> String {
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p
    }

    static let support: String = {
        let dir = home + "/Library/Application Support/Lapang"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// GUI apps start with a bare PATH; give child processes the usual tool locations.
    static let childEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        return env
    }()
}

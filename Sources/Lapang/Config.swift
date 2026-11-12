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
    var sections: [SectionConfig] = []

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

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            names = try c.decodeIfPresent([String].self, forKey: .names) ?? names
        }
        enum CodingKeys: String, CodingKey { case names }
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
        sections = try c.decodeIfPresent([SectionConfig].self, forKey: .sections) ?? sections
    }
    enum CodingKeys: String, CodingKey { case refreshSeconds, disk, xcode, processes, caches, ports, sections }

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
      "processes": { "names": ["dart", "dartvm", "dartaotruntime"] },
      "caches": { "hide": [] },
      "ports": { "minPort": 1024, "maxPort": 49151, "hide": [], "names": {} },
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
}

/// A custom section: an executable that prints JSON (see README, "Custom sections").
struct SectionConfig: Decodable, Identifiable, Hashable {
    let title: String
    let icon: String?
    let command: String
    var id: String { title }
}

enum Paths {
    static let home = NSHomeDirectory()

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

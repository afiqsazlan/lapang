import Darwin
import Foundation

// MARK: - Snapshot

struct Snapshot {
    var config: Config
    var configError: String?

    var freeBytes: Int64
    var totalBytes: Int64
    var pressure: Int  // 1 normal, 2 warning, 4 critical
    var swapUsed: UInt64
    var swapTotal: UInt64

    var memUsed: UInt64 = 0
    var memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var memHistory: [MemoryPoint] = []  // last 24 hours, a point a minute
    var memUsers: [MemoryUser] = []
    var memSpikes: [PressureSpike] = []  // last 7 days

    var sims: [Sim]?  // nil when Xcode's simctl isn't available
    var simStorage: SimStorage? = nil
    var procs: [DevProc]
    var ports: [Listener] = []
    var derivedDataRoot: String
    var derived: [DerivedEntry]
    var caches: [CacheInfo]
    var history: [HistoryPoint]  // last 7 days
    var trend: Trend
    var growth: Growth?
    var sizesMeasuredAt: Date?
    var sections: [SectionState]
    var worktrees: [WorktreeUnit] = []

    var freeGB: Double { Double(freeBytes) / 1_073_741_824 }
    var totalGB: Double { Double(totalBytes) / 1_073_741_824 }
    var usedFraction: Double { totalBytes > 0 ? 1 - Double(freeBytes) / Double(totalBytes) : 0 }
    var swapFraction: Double { swapTotal > 0 ? Double(swapUsed) / Double(swapTotal) : 0 }

    /// The fill rate says free space reaches the warning line soon, though it isn't there yet.
    var forecastWarning: Bool {
        guard diskLevel == .ok, trend.state == .filling, let h = trend.hoursToWarn else { return false }
        return h <= config.disk.forecastHours
    }

    var diskLevel: Level {
        if freeGB < config.disk.criticalGB { return .crit }
        if freeGB < config.disk.warnGB { return .warn }
        return .ok
    }

    var pressureLevel: Level {
        switch pressure {
        case 4: return .crit
        case 2: return .warn
        default: return .ok
        }
    }

    var derivedTotalKB: Int64? { SizeStore.shared.kb(derivedDataRoot) }
}

enum Level { case ok, warn, crit }

struct Sim: Identifiable {
    let udid: String
    let name: String
    var usage = SimUsage()
    var id: String { udid }
}

/// What a booted simulator is being used for, worked out from the processes around it.
struct SimUsage {
    /// Apps installed by you (not system apps) currently running inside the simulator.
    var apps: [(name: String, bundleID: String)] = []
    /// The folder of the `flutter run` / `xcodebuild` driving it, and whether that folder still exists.
    var project: String?
    var projectGone = false
    var tool: String?
    /// The Mac app that started the tool: a terminal, an editor, or Claude Code.
    var launcher: String?
}

struct DevProc: Identifiable {
    let pid: pid_t
    let ppid: pid_t
    let name: String
    let kind: String
    let rssBytes: UInt64  // memory footprint (resident size when that's unavailable)
    let started: Date
    let cwd: String
    let stale: Bool
    /// MCP servers only: when it last used CPU (see MCPActivity) and the agent session that started it.
    var idleSince: Date? = nil
    var session: String? = nil
    var id: pid_t { pid }

    var uptime: String {
        let s = Int(Date().timeIntervalSince(started))
        if s >= 86400 { return "\(s / 86400)d \(s % 86400 / 3600)h" }
        if s >= 3600 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 60)m"
    }
}

struct DerivedEntry: Identifiable {
    enum Status { case protected, live, orphan, new }
    let name: String
    let path: String
    let workspace: String?  // the .xcworkspace / .xcodeproj this cache belongs to
    let lastBuilt: Date
    let status: Status
    let idleDays: Int
    var id: String { name }

    var sizeKB: Int64? { SizeStore.shared.kb(path) }

    /// The project folder: the workspace's parent, minus a platform folder like ios/ or macos/.
    var projectDir: String? {
        guard let w = workspace else { return nil }
        var url = URL(fileURLWithPath: w).deletingLastPathComponent()
        if ["ios", "macos", "osx", "tvos", "watchos"].contains(url.lastPathComponent.lowercased()) {
            url.deleteLastPathComponent()
        }
        return url.path
    }

    /// Last two path components, which tell worktrees apart (e.g. "m4-review/carer-app-v2").
    var title: String {
        guard let dir = projectDir else { return "Unknown project" }
        let parts = dir.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }
}

struct CacheInfo: Identifiable {
    let id: String
    let name: String
    let path: String
    let clearable: Bool
    let note: String?
    var sizeKB: Int64? { SizeStore.shared.kb(path) }
}

struct HistoryPoint: Identifiable, Codable {
    let t: Date
    let freeGB: Double
    var id: Date { t }
}

// MARK: - Engine

enum Engine {
    static func snapshot(sectionsFrom previous: [SectionState]) -> Snapshot {
        let (config, configError) = Config.load()
        let (free, total) = disk()
        let (swapUsed, swapTotal) = swap()
        let root = derivedDataRoot()
        let freeGB = Double(free) / 1_073_741_824
        let history = History.record(freeGB: freeGB)
        let derived = derivedData(root: root, config: config.xcode)
        let caches = caches(hidden: config.caches.hide)
        let devices = SimStorage.loadDevices()
        let snap = Snapshot(
            config: config, configError: configError,
            freeBytes: free, totalBytes: total,
            pressure: sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1,
            swapUsed: swapUsed, swapTotal: swapTotal,
            sims: simulators(devices),
            procs: processes(named: config.processes.names),
            derivedDataRoot: root,
            derived: derived,
            caches: caches,
            history: history,
            trend: Trend.compute(history, freeGB: freeGB, warnGB: config.disk.warnGB),
            growth: GrowthLog.compute(derivedRoot: root, derived: derived, caches: caches,
                                      watch: config.disk.watch.map(Paths.expand), history: history),
            sizesMeasuredAt: SizeStore.shared.measuredAt,
            sections: Sections.run(config.sections)
        )
        var full = snap
        full.simStorage = devices.map { SimStorage(devices: $0, runtimes: SimStorage.loadRuntimes()) }
        let pressure = full.pressure
        full.memUsed = MemoryProbe.used()
        let point = MemoryPoint(t: Date(), pressure: pressure, swapGB: Double(swapUsed) / 1_073_741_824,
                                usedGB: Double(full.memUsed) / 1_073_741_824)
        let recorded = MemoryHistory.record(point)
        let users = MemoryProbe.users(limit: 40)
        full.memHistory = recorded.day
        full.memUsers = Array(users.prefix(8))
        full.memSpikes = PressureSpikes.observe(point, previous: recorded.previous, stored: recorded.stored,
                                                history: recorded.day, users: users)
        full.ports = Ports.discover(config.ports)
        let wt = config.worktrees
        if !wt.repos.isEmpty || !wt.roots.isEmpty {
            full.worktrees = WorktreeStore.shared.units(wt, agentFolders: agentFolders())
        }
        Daily.record(full, memPoints: full.memHistory, diskPoints: history)
        return full
    }

    // Disk: the data volume's real free space (what df reports), not "available for important usage".
    static func disk() -> (Int64, Int64) {
        let url = URL(fileURLWithPath: "/System/Volumes/Data")
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        return (Int64(v?.volumeAvailableCapacity ?? 0), Int64(v?.volumeTotalCapacity ?? 0))
    }

    static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
    }

    static func swap() -> (UInt64, UInt64) {
        var u = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &u, &size, nil, 0) == 0 else { return (0, 0) }
        return (u.xsu_used, u.xsu_total)
    }

    // MARK: Simulators

    static func simulators(_ devices: [SimDevice]?) -> [Sim]? {
        guard let devices else { return nil }
        var sims = devices.filter(\.booted).map { Sim(udid: $0.udid, name: $0.name) }.sorted { $0.name < $1.name }
        attachUsage(&sims)
        return sims
    }

    /// Two kinds of process tie a simulator to its work. Apps run as Mac processes from inside the
    /// simulator's folder. And the tool driving it (`flutter run` streams logs through
    /// `simctl spawn <udid>`; `xcodebuild` takes `-destination id=<udid>`) names its id in its
    /// arguments, so walking up from there finds the tool, its folder, and the app that started it.
    static func attachUsage(_ sims: inout [Sim]) {
        guard !sims.isEmpty else { return }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        for pid in pids.prefix(Int(max(n, 0))) where pid > 0 {
            guard let path = execPath(pid) else { continue }
            let exe = (path as NSString).lastPathComponent
            for i in sims.indices {
                let udid = sims[i].udid
                if path.contains("/CoreSimulator/Devices/\(udid)/data/Containers/Bundle/Application/"),
                   let app = appBundle(path) {
                    if !sims[i].usage.apps.contains(where: { $0.bundleID == app.bundleID }) { sims[i].usage.apps.append(app) }
                } else if (exe == "simctl" || exe == "xcodebuild"), sims[i].usage.project == nil,
                          args(pid).contains(where: { $0.contains(udid) }) {
                    describeDriver(of: pid, into: &sims[i].usage)
                }
            }
        }
    }

    private static func appBundle(_ path: String) -> (name: String, bundleID: String)? {
        guard let r = path.range(of: ".app/") else { return nil }
        let bundle = String(path[..<r.lowerBound]) + ".app"
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: bundle + "/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any]
        else { return nil }
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
            ?? ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
        return (name, (plist["CFBundleIdentifier"] as? String) ?? "")
    }

    private static func describeDriver(of start: pid_t, into usage: inout SimUsage) {
        var pid = start
        for _ in 0 ..< 20 {
            // some links (like the root-owned `login`) hide their path; keep climbing past them
            let path = execPath(pid) ?? ""
            let exe = (path as NSString).lastPathComponent
            let a = args(pid).joined(separator: " ")
            if usage.tool == nil {
                if a.contains("flutter_tools") { usage.tool = "flutter run" }
                else if exe == "xcodebuild" { usage.tool = "xcodebuild" }
                if usage.tool != nil, let cwd = currentDir(pid), !cwd.isEmpty {
                    usage.project = cwd
                    usage.projectGone = !FileManager.default.fileExists(atPath: cwd)
                }
            }
            if exe == "claude" || path.contains("/claude-code/") {
                usage.launcher = "Claude Code"
                break
            }
            if let r = path.range(of: ".app/Contents/MacOS/") {
                // the outermost .app wins: iTerm2 rather than its helper
                usage.launcher = ((String(path[..<r.lowerBound]) as NSString).lastPathComponent)
            }
            guard let parent = parentPID(pid), parent > 1 else { break }
            pid = parent
        }
    }

    /// From the kernel's process table, which (unlike proc_pidinfo) also answers for root-owned
    /// processes such as `login` between a terminal and its shell.
    static func parentPID(_ pid: pid_t) -> pid_t? {
        var k = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &k, &size, nil, 0) == 0, size > 0 else { return nil }
        return k.kp_eproc.e_ppid
    }

    // MARK: Processes (via libproc, no ps/lsof)

    static func processes(named names: [String]) -> [DevProc] {
        guard !names.isEmpty else { return [] }
        let wanted = Set(names)
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var out: [DevProc] = []
        var cpu: [pid_t: UInt64] = [:]
        for pid in pids.prefix(Int(max(n, 0))) where pid > 0 {
            guard let path = execPath(pid) else { continue }
            let name = (path as NSString).lastPathComponent
            guard wanted.contains(name) else { continue }
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { continue }
            var task = proc_taskinfo()
            _ = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size))
            let cwd = currentDir(pid) ?? ""
            let ppid = pid_t(bsd.pbi_ppid)
            let stale = ppid == 1 || (!cwd.isEmpty && !FileManager.default.fileExists(atPath: cwd))
            var p = DevProc(
                pid: pid, ppid: ppid, name: name, kind: kind(name: name, args: args(pid)),
                rssBytes: MemoryProbe.footprint(pid) ?? task.pti_resident_size,
                started: Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)),
                cwd: cwd, stale: stale)
            if p.kind == "mcp" {
                cpu[pid] = MCPActivity.cpuNs(task)
                p.session = agentSession(above: ppid)
            }
            out.append(p)
        }
        let active = MCPActivity.update(out.filter { $0.kind == "mcp" }.map { ($0.pid, $0.started, cpu[$0.pid] ?? 0) })
        for i in out.indices where out[i].kind == "mcp" { out[i].idleSince = active[out[i].pid] }
        return out.sorted { $0.pid < $1.pid }
    }

    /// The agent session (Claude Code, in a terminal or the desktop app) a process belongs to:
    /// "Claude Code · <its folder>".
    static func agentSession(above start: pid_t) -> String? {
        var pid = start
        for _ in 0 ..< 6 where pid > 1 {
            if let path = execPath(pid), isClaudeCode(path) {
                let dir = currentDir(pid).map { ($0 as NSString).lastPathComponent } ?? ""
                return dir.isEmpty ? "Claude Code" : "Claude Code · \(dir)"
            }
            guard let parent = parentPID(pid) else { break }
            pid = parent
        }
        return nil
    }

    static func isClaudeCode(_ path: String) -> Bool {
        (path as NSString).lastPathComponent == "claude" || path.contains("/claude-code/")
    }

    /// The working folders of every running Claude Code session.
    static func agentFolders() -> [String] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var out = Set<String>()
        for pid in pids.prefix(Int(max(n, 0))) where pid > 0 {
            guard let path = execPath(pid), (path as NSString).lastPathComponent == "claude",
                  let cwd = currentDir(pid), !cwd.isEmpty else { continue }
            out.insert(cwd)
        }
        return Array(out)
    }

    static func kind(name: String, args: [String]) -> String {
        let a = args.joined(separator: " ")
        if a.contains(" mcp-server") { return "mcp" }
        if name == "dart" || name == "dartvm" || name == "dartaotruntime" {
            if a.contains("language-server") { return "lsp" }
            if a.contains("development-service") { return "devtools" }
            if a.contains("frontend_server") { return "compiler" }
            if a.contains("flutter_tools.snapshot") { return "flutter" }
        }
        return name
    }

    static func execPath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    static func currentDir(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0
        else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    static func args(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }  // exec path
        while i < size && buf[i] == 0 { i += 1 }  // padding
        var out: [String] = []
        while out.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[start ..< i], as: UTF8.self))
            i += 1
        }
        return out
    }

    // MARK: Xcode DerivedData

    static func derivedDataRoot() -> String {
        if let custom = UserDefaults(suiteName: "com.apple.dt.Xcode")?.string(forKey: "IDECustomDerivedDataLocation"),
           !custom.isEmpty {
            return Paths.expand(custom)
        }
        return Paths.home + "/Library/Developer/Xcode/DerivedData"
    }

    static func derivedData(root: String, config: Config.Xcode) -> [DerivedEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        let protect = config.protect.map { Paths.expand($0).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        let now = Date()
        return names.compactMap { name -> DerivedEntry? in
            // ModuleCache.noindex, SDKStatCaches.noindex etc. are shared by every project
            guard !name.hasSuffix(".noindex"), !name.hasPrefix(".") else { return nil }
            let path = root + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let plist = (try? Data(contentsOf: URL(fileURLWithPath: path + "/info.plist")))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            let workspace = plist?["WorkspacePath"] as? String
            let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? now
            let lastBuilt = (plist?["LastAccessedDate"] as? Date) ?? modified
            let idle = max(0, Int(now.timeIntervalSince(lastBuilt) / 86400))

            let status: DerivedEntry.Status
            if let w = workspace {
                let trimmed = w.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if protect.contains(where: { trimmed == $0 || trimmed.hasPrefix($0 + "/") }) {
                    status = .protected
                } else if fm.fileExists(atPath: w) {
                    status = .live
                } else {
                    status = .orphan
                }
            } else {
                // Xcode writes info.plist once a build gets going; older ones without it are leftovers
                status = idle >= 1 ? .orphan : .new
            }
            return DerivedEntry(name: name, path: path, workspace: workspace, lastBuilt: lastBuilt,
                                status: status, idleDays: idle)
        }
    }

    // MARK: Package caches

    static let knownCaches: [(id: String, name: String, path: String, clearable: Bool, note: String?)] = [
        ("npm", "npm", "~/.npm", true, nil),
        ("yarn", "Yarn", "~/Library/Caches/Yarn", true, nil),
        ("pnpm", "pnpm store", "~/Library/pnpm/store", false, "run pnpm store prune to trim"),
        ("cocoapods", "CocoaPods", "~/Library/Caches/CocoaPods", true, nil),
        ("gradle", "Gradle", "~/.gradle/caches", true, nil),
        ("homebrew", "Homebrew", "~/Library/Caches/Homebrew", true, nil),
        ("pub", "pub", "~/.pub-cache", false, "shared by every Dart project, kept"),
        ("devicesupport", "iOS DeviceSupport", "~/Library/Developer/Xcode/iOS DeviceSupport", true, nil),
        ("archives", "Xcode archives", "~/Library/Developer/Xcode/Archives", false, "delete old ones in Xcode's Organizer"),
    ]

    static func caches(hidden: [String]) -> [CacheInfo] {
        knownCaches
            .filter { !hidden.contains($0.id) && FileManager.default.fileExists(atPath: Paths.expand($0.path)) }
            .map { CacheInfo(id: $0.id, name: $0.name, path: Paths.expand($0.path), clearable: $0.clearable, note: $0.note) }
    }
}

// MARK: - Folder sizes (measured in the background; du is the slow part)

final class SizeStore: @unchecked Sendable {
    static let shared = SizeStore()
    private let lock = NSLock()
    private var sizes: [String: Int64] = [:]
    private(set) var measuredAt: Date?
    private(set) var measuring = false
    private let file = Paths.support + "/sizes.json"
    static let interval: TimeInterval = 30 * 60

    private struct Stored: Codable { let measuredAt: Date; let sizes: [String: Int64] }

    init() {
        if let d = FileManager.default.contents(atPath: file), let s = try? JSONDecoder().decode(Stored.self, from: d) {
            sizes = s.sizes
            measuredAt = s.measuredAt
        }
    }

    func kb(_ path: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return sizes[path]
    }

    var isDue: Bool {
        lock.lock(); defer { lock.unlock() }
        guard !measuring else { return false }
        guard let t = measuredAt else { return true }
        return Date().timeIntervalSince(t) > Self.interval
    }

    /// Runs du on each path. Call off the main thread.
    func measure(_ paths: [String]) {
        lock.lock()
        if measuring { lock.unlock(); return }
        measuring = true
        lock.unlock()

        var fresh: [String: Int64] = [:]
        for p in paths where FileManager.default.fileExists(atPath: p) {
            if let kb = Self.du(p) { fresh[p] = kb }
        }

        lock.lock()
        sizes = fresh
        measuredAt = Date()
        measuring = false
        let stored = Stored(measuredAt: measuredAt!, sizes: fresh)
        lock.unlock()
        if let d = try? JSONEncoder().encode(stored) { try? d.write(to: URL(fileURLWithPath: file)) }
        GrowthLog.append(.init(t: stored.measuredAt, sizes: fresh))
    }

    /// Kilobytes used under a folder, from du at low priority.
    static func du(_ path: String) -> Int64? {
        guard let r = Shell.run("/usr/bin/nice", ["-n", "15", "/usr/bin/du", "-sk", path]) else { return nil }
        return String(decoding: r.out, as: UTF8.self).split(separator: "\t").first.flatMap { Int64($0) }
    }

    /// Sample sizes for the demo render; kept in memory only, never saved.
    func useDemo(_ demo: [String: Int64]) {
        lock.lock(); defer { lock.unlock() }
        sizes = demo
        measuredAt = Date()
    }

    func forget(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        sizes[path] = nil
    }
}

// MARK: - Free-space history (a point every 5 minutes, 7 days kept)

enum History {
    private static let file = Paths.support + "/history.json"
    nonisolated(unsafe) private static var cache: [HistoryPoint]?
    private static let lock = NSLock()

    static func record(freeGB: Double) -> [HistoryPoint] {
        lock.lock(); defer { lock.unlock() }
        var points = cache ?? {
            guard let d = FileManager.default.contents(atPath: file) else { return [] }
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .secondsSince1970
            return (try? dec.decode([HistoryPoint].self, from: d)) ?? []
        }()
        let now = Date()
        if points.last.map({ now.timeIntervalSince($0.t) >= 300 }) ?? true {
            points.append(HistoryPoint(t: now, freeGB: freeGB))
            points.removeAll { now.timeIntervalSince($0.t) > 7 * 86400 }
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .secondsSince1970
            if let d = try? enc.encode(points) { try? d.write(to: URL(fileURLWithPath: file)) }
        }
        cache = points
        return points
    }
}

// MARK: - Running other programs

enum Shell {
    struct Result {
        let status: Int32
        let out: Data
        let err: Data
        var text: String { String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        var errText: String { String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Runs a program and waits. Blocking: call off the main thread.
    static func run(_ exe: String, _ args: [String], env extra: [String: String] = [:]) -> Result? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = Paths.childEnvironment.merging(extra) { $1 }
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return nil }
        // read both pipes concurrently so a chatty stderr can't block the child
        var errData = Data()
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        g.wait()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, out: outData, err: errData)
    }
}

extension Snapshot {
    /// Everything the background size check measures.
    var measuredPaths: [String] {
        [derivedDataRoot] + derived.map(\.path) + caches.map(\.path) + config.disk.watch.map(Paths.expand)
            + (simStorage?.measuredPaths ?? [])
    }
}

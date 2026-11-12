import Darwin
import Foundation

// One row per day of what the Mac went through, for the share cards: the busiest moment of the
// day (simulators, dev processes, MCP servers, memory demand), how many `flutter run`s and which
// project folders were in use, plus a summary of the minute-by-minute memory and disk history
// that outlives its 7-day window. Kept for 400 days in Application Support/Lapang/daily.json.
// Project folders are stored here so the count is right; a card only shows them when asked to.

struct DayStats: Codable {
    let day: String  // yyyy-MM-dd, local time
    var peakSims = 0
    var peakDevProcs = 0
    var peakMCP = 0
    /// Total footprint of all memory users at the busiest minute.
    var peakAppsBytes: UInt64 = 0
    var memTotalBytes: UInt64 = 0
    var flutterRunPids: Set<Int32> = []
    var projects: Set<String> = []
    var xcodeBuilds = 0
    var peakSwapGB = 0.0
    var minFreeGB: Double?
    var pressuredMinutes = 0
    var sampledMinutes = 0

    init(day: String) { self.day = day }

    var flutterRuns: Int { flutterRunPids.count }
}

enum Daily {
    static let file = Paths.support + "/daily.json"
    static let keepDays = 400

    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(_ d: Date) -> String { dayFormat.string(from: d) }

    /// Folds the current snapshot into today's row. Called on every refresh, from the app and the CLI.
    static func record(_ s: Snapshot, memPoints: [MemoryPoint], diskPoints: [HistoryPoint]) {
        let now = Date()
        let today = key(now)
        update { rows in
            var r = rows.last(where: { $0.day == today }) ?? DayStats(day: today)
            r.peakSims = max(r.peakSims, s.sims?.count ?? 0)
            r.peakDevProcs = max(r.peakDevProcs, s.procs.count)
            r.peakMCP = max(r.peakMCP, s.procs.filter { $0.kind == "mcp" }.count)
            let apps = s.memUsers.reduce(UInt64(0)) { $0 + $1.bytes }
            if apps > r.peakAppsBytes { r.peakAppsBytes = apps }
            r.memTotalBytes = s.memTotal
            for p in s.procs where p.kind == "flutter" { r.flutterRunPids.insert(p.pid) }
            r.projects.formUnion(projectFolders(s))
            r.xcodeBuilds = max(r.xcodeBuilds, xcodeBuilds(root: s.derivedDataRoot, on: now))
            let start = Calendar.current.startOfDay(for: now)
            let mem = memPoints.filter { $0.t >= start }
            if !mem.isEmpty {
                r.peakSwapGB = max(r.peakSwapGB, mem.map(\.swapGB).max() ?? 0)
                r.pressuredMinutes = max(r.pressuredMinutes, mem.filter { $0.pressure >= 2 }.count)
                r.sampledMinutes = max(r.sampledMinutes, mem.count)
            }
            let free = diskPoints.filter { $0.t >= start }.map(\.freeGB) + [s.freeGB]
            r.minFreeGB = min(r.minFreeGB ?? .infinity, free.min() ?? s.freeGB)
            rows.removeAll { $0.day == today }
            rows.append(r)
            let cutoff = key(now.addingTimeInterval(-Double(keepDays) * 86400))
            rows.removeAll { $0.day < cutoff }
        }
    }

    static func all() -> [DayStats] {
        guard let d = FileManager.default.contents(atPath: file) else { return [] }
        return (try? JSONDecoder().decode([DayStats].self, from: d)) ?? []
    }

    static func today() -> DayStats? { all().last { $0.day == key(Date()) } }

    /// The app and the CLI can both write, so read-modify-write happens under a file lock.
    private static func update(_ change: (inout [DayStats]) -> Void) {
        let fd = open(file, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let existing = (try? h.readToEnd()) ?? Data()
        var rows = (try? JSONDecoder().decode([DayStats].self, from: existing)) ?? []
        change(&rows)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let out = try? enc.encode(rows) else { return }
        ftruncate(fd, 0)
        try? h.seek(toOffset: 0)
        try? h.write(contentsOf: out)
    }

    /// Folders in use right now: what simulators and dev processes run from, and Xcode projects built today.
    static func projectFolders(_ s: Snapshot) -> Set<String> {
        var out = Set<String>()
        for sim in s.sims ?? [] { if let p = sim.usage.project { out.insert(p) } }
        for p in s.procs where !p.cwd.isEmpty && p.cwd != "/" && p.cwd != Paths.home { out.insert(p.cwd) }
        let start = Calendar.current.startOfDay(for: Date())
        for d in s.derived where d.lastBuilt >= start { if let p = d.projectDir { out.insert(p) } }
        return out
    }

    /// Xcode writes one .xcactivitylog per build into each project's DerivedData/…/Logs/Build.
    static func xcodeBuilds(root: String, on day: Date) -> Int {
        let start = Calendar.current.startOfDay(for: day)
        let end = start.addingTimeInterval(86400)
        let fm = FileManager.default
        var n = 0
        for dir in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let logs = root + "/" + dir + "/Logs/Build"
            for f in (try? fm.contentsOfDirectory(atPath: logs)) ?? [] where f.hasSuffix(".xcactivitylog") {
                if let m = (try? fm.attributesOfItem(atPath: logs + "/" + f))?[.modificationDate] as? Date,
                   m >= start, m < end { n += 1 }
            }
        }
        return n
    }

    /// Claude Code sessions with activity on each day: transcripts last written that day.
    /// Only counted, at share time; nothing is read from the transcripts.
    static func claudeSessions(days: [Date]) -> [String: Int] {
        let root = Paths.home + "/.claude/projects"
        let fm = FileManager.default
        let wanted = Set(days.map(key))
        var out: [String: Int] = [:]
        for dir in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let path = root + "/" + dir
            for f in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where f.hasSuffix(".jsonl") {
                guard let m = (try? fm.attributesOfItem(atPath: path + "/" + f))?[.modificationDate] as? Date else { continue }
                let k = key(m)
                if wanted.contains(k) { out[k, default: 0] += 1 }
            }
        }
        return out
    }
}

import Foundation

// What goes on a share card, worked out from the snapshot, the daily rollup and the action log.
// Privacy: a card shows counts, sizes and well-known app names only. Paths, user and host names,
// branches, the apps inside simulators, custom sections, ports and process arguments never appear.
// Project folders show as "worktree/repo" only when the person turns on "Show project names".

enum ShareKind: String, CaseIterable, Identifiable {
    case now, today, week, clean
    var id: String { rawValue }
    var title: String {
        switch self {
        case .now: "Right now"
        case .today: "Today"
        case .week: "This week"
        case .clean: "After clean"
        }
    }
}

enum ShareRatio: String, CaseIterable, Identifiable {
    case wide, square, portrait, story
    var id: String { rawValue }
    var label: String {
        switch self {
        case .wide: "16:9"
        case .square: "1:1"
        case .portrait: "4:5"
        case .story: "9:16"
        }
    }
    /// Pixel size at 1x, the size X, Threads, LinkedIn and Instagram expect.
    var size: CGSize {
        switch self {
        case .wide: CGSize(width: 1200, height: 675)
        case .square: CGSize(width: 1080, height: 1080)
        case .portrait: CGSize(width: 1080, height: 1350)
        case .story: CGSize(width: 1080, height: 1920)
        }
    }
    static func parse(_ s: String) -> ShareRatio? {
        let t = s.lowercased()
        return allCases.first { $0.rawValue == t || $0.label == t }
            ?? ["16x9": .wide, "x": .wide, "1x1": .square, "4x5": .portrait, "9x16": .story][t]
    }
}

struct ReceiptRow: Identifiable {
    let label: String
    let value: String
    var note: String? = nil
    var accent = false
    var id: String { label }
}

struct AppSlice: Identifiable {
    let name: String
    let gb: Double
    var id: String { name }
}

/// Where the history behind a card comes from: this Mac's files, or sample data for `--demo`.
struct ShareSources {
    var days: () -> [DayStats]
    var memory: () -> [MemoryPoint]
    var actions: () -> [ActionEntry]
    var claudeSessions: ([Date]) -> [String: Int]
    var xcodeBuilds: (String, Date) -> Int

    static let live = ShareSources(days: Daily.all, memory: MemoryHistory.all, actions: { ActionLog.recent() },
                                   claudeSessions: { Daily.claudeSessions(days: $0) },
                                   xcodeBuilds: { Daily.xcodeBuilds(root: $0, on: $1) })
}

enum ShareContent {
    struct Now {
        let apps: [AppSlice]
        let appsGB: Double
        let ramGB: Double
        let swap: [(t: Date, gb: Double)]
        let peakSwapGB: Double
        let pressuredShare: Double?
        let simProcesses: Int
    }
    struct Today {
        let date: Date
        let headline: String
        let rows: [ReceiptRow]
        let strip: [Int]  // max pressure per bar
        let minutesPerBar: Int
        let stripStart: Date?
        let stripEnd: Date?
        let pressuredShare: Double?
        let sampledMinutes: Int
    }
    struct Week {
        let since: Date
        let headline: String
        let rows: [ReceiptRow]
        /// One row per day (oldest first) of 24 hourly cells: share of minutes under pressure, nil without data.
        let heat: [(day: Date, hours: [Double?])]
    }
    struct Clean {
        let time: Date
        let headline: String
        let sub: String
        let rows: [ReceiptRow]
        let ramBeforeGB: Double?
        let ramAfterGB: Double?
        let ramGB: Double
    }

    case now(Now), today(Today), week(Week), clean(Clean?)
}

extension ShareContent {
    static func make(_ kind: ShareKind, _ s: Snapshot, names: Bool, src: ShareSources = .live) -> ShareContent {
        switch kind {
        case .now: .now(now(s))
        case .today: .today(today(s, names: names, src: src))
        case .week: .week(week(s, src: src))
        case .clean: .clean(clean(s, src: src))
        }
    }

    static let gb = 1_073_741_824.0

    /// Well-known apps by name; anything not installed in /Applications or /System folds into "Other".
    static func apps(_ s: Snapshot) -> [AppSlice] {
        var out: [AppSlice] = []
        var other = 0.0
        for u in s.memUsers {
            let v = Double(u.bytes) / gb
            switch u.kind {
            case .simulators: out.append(AppSlice(name: "iOS Simulators", gb: v))
            case .app:
                if let b = u.bundlePath, b.hasPrefix("/Applications/") || b.hasPrefix("/System/") {
                    out.append(AppSlice(name: u.name, gb: v))
                } else { other += v }
            case .other:
                switch u.name {
                case "Dart and Flutter": out.append(AppSlice(name: "Dart & Flutter", gb: v))
                case "Claude Code sessions": out.append(AppSlice(name: "Claude Code", gb: v))
                default: other += v
                }
            }
        }
        out.sort { $0.gb > $1.gb }
        if out.count > 6 { other += out.dropFirst(6).reduce(0) { $0 + $1.gb }; out = Array(out.prefix(6)) }
        if other >= 0.05 { out.append(AppSlice(name: "Other", gb: other)) }
        return out
    }

    static func todaysMemory(_ s: Snapshot) -> [MemoryPoint] {
        let start = Calendar.current.startOfDay(for: Date())
        return s.memHistory.filter { $0.t >= start }
    }

    static func now(_ s: Snapshot) -> Now {
        let a = apps(s)
        let mem = todaysMemory(s)
        return Now(apps: a, appsGB: a.reduce(0) { $0 + $1.gb }, ramGB: Double(s.memTotal) / gb,
                   swap: mem.map { ($0.t, $0.swapGB) },
                   peakSwapGB: max(mem.map(\.swapGB).max() ?? 0, Double(s.swapUsed) / gb),
                   pressuredShare: MemoryHistory.pressuredShare(s.memHistory),
                   simProcesses: s.memUsers.first { $0.kind == .simulators }?.processes ?? 0)
    }

    static func today(_ s: Snapshot, names: Bool, src: ShareSources) -> Today {
        let d = src.days().last { $0.day == Daily.key(Date()) } ?? DayStats(day: Daily.key(Date()))
        let mem = todaysMemory(s)
        let ram = Double(s.memTotal) / gb
        let claude = src.claudeSessions([Date()]).values.reduce(0, +)
        let builds = max(d.xcodeBuilds, src.xcodeBuilds(s.derivedDataRoot, Date()))
        var rows: [ReceiptRow] = []
        func add(_ label: String, _ n: Int, note: String? = nil) {
            if n > 0 { rows.append(ReceiptRow(label: label, value: "\(n)", note: note)) }
        }
        add("Simulators booted", max(d.peakSims, s.sims?.count ?? 0))
        let projects = d.projects.isEmpty ? Daily.projectFolders(s) : d.projects
        add("Projects and worktrees", projects.count,
            note: names ? projects.map(shortName).sorted().prefix(2).joined(separator: ", ") : nil)
        add("Xcode builds", builds)
        add("Flutter runs", d.flutterRuns)
        add("Dev processes", max(d.peakDevProcs, s.procs.count), note: "at peak")
        add("MCP servers", max(d.peakMCP, s.procs.filter { $0.kind == "mcp" }.count), note: "at peak")
        add("Claude Code sessions", claude)
        let peakSwap = max(d.peakSwapGB, mem.map(\.swapGB).max() ?? 0)
        if peakSwap >= 0.1 {
            rows.append(ReceiptRow(label: "Peak swap", value: gbText(peakSwap), note: "on \(Int(ram.rounded())) GB RAM", accent: true))
        }
        let minFree = min(d.minFreeGB ?? s.freeGB, s.freeGB)
        rows.append(ReceiptRow(label: "Lowest free disk", value: gbText(minFree), note: "of \(Int(s.totalGB.rounded()))"))
        if let kb = s.derivedTotalKB, kb > 0 {
            rows.append(ReceiptRow(label: "Build caches", value: human(kb: kb), note: "\(s.derived.count) projects"))
        }

        let pressured = mem.filter { $0.pressure >= 2 }.count
        let share = mem.count >= 10 ? Double(pressured) / Double(mem.count) : nil
        var headline = "A day on my Mac."
        if let first = mem.first, mem.count >= 30, pressured == mem.count {
            let sinceMidnight = first.t.timeIntervalSince(Calendar.current.startOfDay(for: first.t)) < 15 * 60
            headline = sinceMidnight ? "Under memory pressure all day." : "Under memory pressure every minute since \(clock(first.t))."
        } else if pressured >= 60 {
            headline = "Under memory pressure for \(durationShort(minutes: pressured)) today."
        } else if peakSwap >= ram {
            headline = "\(gbText(peakSwap)) of swap on a \(Int(ram.rounded())) GB Mac."
        }

        let bars = 144
        let per = max(1, Int((Double(mem.count) / Double(bars)).rounded(.up)))
        var strip: [Int] = []
        var i = 0
        while i < mem.count {
            strip.append(mem[i..<min(i + per, mem.count)].map(\.pressure).max() ?? 1)
            i += per
        }
        return Today(date: Date(), headline: headline, rows: rows, strip: strip, minutesPerBar: per,
                     stripStart: mem.first?.t, stripEnd: mem.last?.t, pressuredShare: share, sampledMinutes: mem.count)
    }

    static func week(_ s: Snapshot, src: ShareSources = .live) -> Week {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let days = (0..<7).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
        let rollups = Dictionary(src.days().map { ($0.day, $0) }, uniquingKeysWith: { $1 })
        let points = src.memory()
        var heat: [(Date, [Double?])] = []
        var pressuredMinutes = 0
        var busiest: (Date, Int)?
        for day in days {
            var hours: [Double?] = Array(repeating: nil, count: 24)
            let dayPts = points.filter { cal.isDate($0.t, inSameDayAs: day) }
            for h in 0..<24 {
                let p = dayPts.filter { cal.component(.hour, from: $0.t) == h }
                if !p.isEmpty { hours[h] = Double(p.filter { $0.pressure >= 2 }.count) / Double(p.count) }
            }
            heat.append((day, hours))
            let m = max(dayPts.filter { $0.pressure >= 2 }.count, rollups[Daily.key(day)]?.pressuredMinutes ?? 0)
            pressuredMinutes += m
            if m > (busiest?.1 ?? 0) { busiest = (day, m) }
        }
        let firstData = days.first { day in
            heat.first { $0.0 == day }?.1.contains { $0 != nil } == true || rollups[Daily.key(day)] != nil
        } ?? today
        let weekRollups = days.compactMap { rollups[Daily.key($0)] }
        let claude = src.claudeSessions(days).values.reduce(0, +)
        let builds = days.reduce(0) { sum, day in
            sum + max(rollups[Daily.key(day)]?.xcodeBuilds ?? 0, src.xcodeBuilds(s.derivedDataRoot, day))
        }
        let since = days.first ?? today
        let actions = src.actions().filter { $0.time >= since && $0.result == "ok" }
        let disk = actions.compactMap(\.diskFreedBytes).reduce(0, +)
        let ramFreed = actions.compactMap(\.memoryFreedBytes).reduce(0, +)
        let peakSwap = max(weekRollups.map(\.peakSwapGB).max() ?? 0, points.filter { $0.t >= since }.map(\.swapGB).max() ?? 0)
        let minFree = (weekRollups.compactMap(\.minFreeGB) + [s.freeGB]).min() ?? s.freeGB

        var rows: [ReceiptRow] = []
        if peakSwap >= 0.1 {
            rows.append(ReceiptRow(label: "Peak swap", value: gbText(peakSwap),
                                   note: "on \(Int((Double(s.memTotal) / gb).rounded())) GB RAM", accent: true))
        }
        rows.append(ReceiptRow(label: "Lowest free disk", value: gbText(minFree), note: "of \(Int(s.totalGB.rounded()))"))
        if builds > 0 { rows.append(ReceiptRow(label: "Xcode builds", value: "\(builds)")) }
        let runs = weekRollups.map(\.flutterRuns).reduce(0, +)
        if runs > 0 { rows.append(ReceiptRow(label: "Flutter runs", value: "\(runs)")) }
        if claude > 0 { rows.append(ReceiptRow(label: "Claude Code sessions", value: "\(claude)")) }
        let peakSims = weekRollups.map(\.peakSims).max() ?? 0
        if peakSims > 0 { rows.append(ReceiptRow(label: "Most simulators at once", value: "\(peakSims)")) }
        if disk + ramFreed >= 100 << 20 {
            let parts = [disk > 0 ? human(bytes: disk) + " disk" : nil, ramFreed > 0 ? human(bytes: ramFreed) + " RAM" : nil]
            rows.append(ReceiptRow(label: "Freed", value: parts.compactMap { $0 }.joined(separator: " + ")))
        }
        if let b = busiest, weekRollups.count > 1 || heat.filter({ $0.1.contains { $0 != nil } }).count > 1 {
            rows.append(ReceiptRow(label: "Busiest day", value: b.0.formatted(.dateTime.weekday(.wide))))
        }
        let headline = pressuredMinutes >= 60
            ? "\(durationShort(minutes: pressuredMinutes)) under memory pressure this week."
            : "A week on my Mac."
        return Week(since: firstData, headline: headline, rows: rows, heat: heat)
    }

    /// The most recent bulk clean (or, failing that, what was done in the last hour).
    static func clean(_ s: Snapshot, src: ShareSources) -> Clean? {
        let recent = src.actions().filter { Date().timeIntervalSince($0.time) < 86400 && $0.result == "ok" }
        var group: [ActionEntry]
        var oneClick = false
        if let last = recent.first(where: { $0.batch != nil }) {
            group = recent.filter { $0.batch == last.batch && abs($0.time.timeIntervalSince(last.time)) < 600 }
            oneClick = last.batch == "clean all"
        } else {
            group = recent.filter { Date().timeIntervalSince($0.time) < 3600 }
        }
        group.removeAll { $0.action == "section action" }
        guard let newest = group.first else { return nil }
        if !oneClick { group = recent.filter { abs($0.time.timeIntervalSince(newest.time)) < 600 && $0.action != "section action" } }

        var buckets: [(label: String, n: Int, disk: Int64, ram: Int64)] = []
        func bucket(_ e: ActionEntry) -> String {
            switch e.action {
            case "shut down simulator", "shut down all simulators": return "simulator"
            case "delete build cache": return "build cache"
            case "clear package cache": return "package cache"
            case "quit app": return "app"
            case "stop port": return "dev server"
            case "section action": return "skip"
            case let a where a.contains("kill"): return e.target["kind"] == "mcp" ? "MCP server"
                : (e.target["kind"] == "lsp" ? "language server" : "dev process")
            default: return "other"
            }
        }
        for e in group {
            let b = bucket(e)
            if b == "skip" { continue }
            if let i = buckets.firstIndex(where: { $0.label == b }) {
                buckets[i].n += 1; buckets[i].disk += e.diskFreedBytes ?? 0; buckets[i].ram += e.memoryFreedBytes ?? 0
            } else {
                buckets.append((b, 1, e.diskFreedBytes ?? 0, e.memoryFreedBytes ?? 0))
            }
        }
        let verbs = ["simulator": "shut down", "build cache": "deleted", "package cache": "cleared", "app": "quit",
                     "MCP server": "stopped", "language server": "stopped", "dev process": "stopped", "dev server": "stopped", "other": "done"]
        let rows = buckets.map { b -> ReceiptRow in
            let noun = b.label == "other" ? "other action" : b.label
            let label = "\(b.n) \(noun)\(b.n == 1 ? "" : (noun.hasSuffix("s") ? "es" : "s")) \(verbs[b.label] ?? "done")"
            if b.ram > 0 { return ReceiptRow(label: label, value: human(bytes: b.ram), note: "RAM") }
            if b.disk > 0 { return ReceiptRow(label: label, value: human(bytes: b.disk), note: "disk") }
            return ReceiptRow(label: label, value: "✓")
        }
        let disk = group.compactMap(\.diskFreedBytes).reduce(0, +)
        let ram = group.compactMap(\.memoryFreedBytes).reduce(0, +)
        // a stopped dev server or two isn't worth a card
        guard disk + ram >= 100 << 20 || group.count >= 3 else { return nil }
        var parts: [String] = []
        if ram > 0 { parts.append(human(bytes: ram) + " of RAM") }
        if disk > 0 { parts.append(human(bytes: disk) + " of disk") }
        let sub = parts.isEmpty
            ? "Cleaned up \(group.count) thing\(group.count == 1 ? "" : "s")\(oneClick ? " in one click" : "")."
            : "Freed " + parts.joined(separator: " and ") + (oneClick ? " in one click." : ".")
        // RAM before and after, if it was freed recently enough for "now" to be the after.
        let appsNow = s.memUsers.reduce(0.0) { $0 + Double($1.bytes) / gb }
        let fresh = Date().timeIntervalSince(newest.time) < 1800 && ram >= 512 << 20
        return Clean(time: newest.time, headline: "Rasa lapang.", sub: sub, rows: rows,
                     ramBeforeGB: fresh ? appsNow + Double(ram) / gb : nil, ramAfterGB: fresh ? appsNow : nil,
                     ramGB: Double(s.memTotal) / gb)
    }

    static func shortName(_ path: String) -> String {
        path.split(separator: "/").suffix(2).joined(separator: "/")
    }
}

func gbText(_ v: Double) -> String { String(format: v >= 100 ? "%.0f GB" : "%.1f GB", v) }

func clock(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: d)
}

func durationShort(minutes m: Int) -> String {
    if m < 60 { return "\(m) min" }
    return m % 60 == 0 || m >= 600 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
}

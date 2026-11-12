import Foundation

// Sample history for `lapang share <card> --demo`, used for the README images and for checking
// layouts without real data. Pairs with Demo.snapshot().

extension ShareSources {
    static func demo(_ s: Snapshot) -> ShareSources {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let now = Date()

        // a working week: pressure through the afternoons, worst mid-week, a quiet weekend
        var mem: [MemoryPoint] = []
        for back in (0..<7).reversed() {
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            let weekend = cal.isDateInWeekend(day)
            for minute in stride(from: 8 * 60, to: 23 * 60, by: 1) {
                let t = day.addingTimeInterval(Double(minute) * 60)
                if t > now { break }
                let h = minute / 60
                let busy = !weekend && (10...12).contains(h) || !weekend && (14...19).contains(h) && (back + h) % 5 != 0
                let spike = busy && minute % 97 == 0
                mem.append(MemoryPoint(t: t, pressure: spike ? 4 : (busy ? 2 : 1),
                                       swapGB: busy ? 9 + Double((minute + back * 37) % 90) / 10 : 2.5,
                                       usedGB: busy ? 33 : 24))
            }
        }
        let todayMem = s.memHistory.filter { $0.t >= today }
        mem.removeAll { $0.t >= today }
        mem += todayMem

        var days: [DayStats] = []
        for back in (0..<7).reversed() {
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            var r = DayStats(day: Daily.key(day))
            let pts = mem.filter { cal.isDate($0.t, inSameDayAs: day) }
            r.peakSims = cal.isDateInWeekend(day) ? 0 : 2 + back % 2
            r.peakDevProcs = 9 + back
            r.peakMCP = 3 + back % 3
            r.flutterRunPids = Set((0..<Int32(cal.isDateInWeekend(day) ? 0 : 4 + back % 4)).map { 1000 * Int32(back + 1) + $0 })
            r.projects = Set((0..<(3 + back % 4)).map { "/Users/demo/code/.worktrees/feature-\($0)/my-app" })
            r.xcodeBuilds = cal.isDateInWeekend(day) ? 0 : 6 + back * 2 % 7
            r.peakSwapGB = pts.map(\.swapGB).max() ?? 0
            r.pressuredMinutes = pts.filter { $0.pressure >= 2 }.count
            r.sampledMinutes = pts.count
            r.minFreeGB = 18.4 + Double(back)
            r.memTotalBytes = s.memTotal
            days.append(r)
        }

        // "Clean all" a few minutes ago
        func entry(_ action: String, _ title: String, kind: String? = nil, disk: Int64? = nil, ram: Int64? = nil) -> ActionEntry {
            ActionEntry(time: now.addingTimeInterval(-240), source: "panel", action: action, title: title,
                        target: kind.map { ["kind": $0] } ?? [:], result: "ok",
                        diskFreedBytes: disk, memoryFreedBytes: ram, batch: "clean all", version: "demo")
        }
        let actions = [
            entry("shut down simulator", "iPhone 16 Pro", ram: 2_900 << 20),
            entry("shut down simulator", "iPad Air", ram: 2_300 << 20),
            entry("kill process", "dart (pid 4821)", kind: "mcp", ram: 1_250 << 20),
            entry("kill process", "dart (pid 4835)", kind: "mcp", ram: 1_100 << 20),
            entry("kill stale process", "dart (pid 3377)", kind: "devtools", ram: 95 << 20),
            entry("delete build cache", "old/my-app", disk: 3_900 << 20),
            entry("delete build cache", "spike/payments", disk: 1_800 << 20),
        ]

        return ShareSources(days: { days }, memory: { mem }, actions: { actions },
                            claudeSessions: { ds in Dictionary(uniqueKeysWithValues: ds.map { (Daily.key($0), cal.isDateInWeekend($0) ? 2 : 11) }) },
                            xcodeBuilds: { _, day in days.first { $0.day == Daily.key(day) }?.xcodeBuilds ?? 0 })
    }
}

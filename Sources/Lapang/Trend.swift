import Foundation

// MARK: - Fill rate and forecast

struct Trend {
    enum State { case learning, steady, filling, freeing }
    let state: State
    /// GB per day; negative while the disk is filling.
    let ratePerDay: Double
    /// How much history the rate is based on.
    let span: TimeInterval
    /// True when the window starts after a cleanup (a jump in free space), not 24h back.
    let sinceCleanup: Bool
    let hoursToWarn: Double?
    let hoursToFull: Double?

    /// A straight-line fit over the last 24 hours of free-space samples, restarting after any
    /// cleanup: a sudden gain of 2 GB or more would otherwise read as the disk freeing itself.
    static func compute(_ history: [HistoryPoint], freeGB: Double, warnGB: Double) -> Trend {
        let now = Date()
        var pts = history.filter { now.timeIntervalSince($0.t) <= 86400 }
        var sinceCleanup = false
        if let jump = pts.indices.dropFirst().last(where: { pts[$0].freeGB - pts[$0 - 1].freeGB >= 2 }) {
            pts = Array(pts[jump...])
            sinceCleanup = true
        }
        let span = (pts.last?.t.timeIntervalSince(pts.first?.t ?? now)) ?? 0
        guard pts.count >= 6, span >= 2 * 3600 else {
            return Trend(state: .learning, ratePerDay: 0, span: span, sinceCleanup: sinceCleanup,
                         hoursToWarn: nil, hoursToFull: nil)
        }

        let t0 = pts[0].t.timeIntervalSince1970
        let xs = pts.map { $0.t.timeIntervalSince1970 - t0 }
        let ys = pts.map(\.freeGB)
        let n = Double(pts.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let sxx = zip(xs, xs).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - mx) }
        let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let perSecond = sxx > 0 ? sxy / sxx : 0
        let perDay = perSecond * 86400

        if abs(perDay) < 0.5 {
            return Trend(state: .steady, ratePerDay: perDay, span: span, sinceCleanup: sinceCleanup,
                         hoursToWarn: nil, hoursToFull: nil)
        }
        if perDay > 0 {
            return Trend(state: .freeing, ratePerDay: perDay, span: span, sinceCleanup: sinceCleanup,
                         hoursToWarn: nil, hoursToFull: nil)
        }
        let perHour = -perDay / 24
        return Trend(state: .filling, ratePerDay: perDay, span: span, sinceCleanup: sinceCleanup,
                     hoursToWarn: max(0, (freeGB - warnGB) / perHour),
                     hoursToFull: freeGB / perHour)
    }
}

func durationText(hours h: Double) -> String {
    if h < 1 { return "under an hour" }
    if h < 48 { return "~\(Int(h.rounded())) h" }
    return "~\(Int((h / 24).rounded())) days"
}

// MARK: - What's growing

struct Growth {
    let since: Date
    let items: [GrowthItem]
    /// Disk used that no measured folder accounts for (simulators, app data, downloads…).
    let untrackedKB: Int64?
}

struct GrowthItem: Identifiable {
    let name: String
    let deltaKB: Int64
    let detail: String?
    var id: String { name }
}

/// Every background size measurement, kept 8 days, so today's sizes can be compared with yesterday's.
enum GrowthLog {
    struct Entry: Codable {
        let t: Date
        let sizes: [String: Int64]
    }

    private static let file = Paths.support + "/growth.json"
    private static let lock = NSLock()

    static func load() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        guard let d = FileManager.default.contents(atPath: file) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode([Entry].self, from: d)) ?? []
    }

    static func append(_ e: Entry) {
        var all = load()
        lock.lock(); defer { lock.unlock() }
        all.append(e)
        all.removeAll { e.t.timeIntervalSince($0.t) > 8 * 86400 }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(all) { try? d.write(to: URL(fileURLWithPath: file)) }
    }

    /// Compares the latest measurement with the one closest to 24 hours before it
    /// (or the oldest, while there's less than a day of measurements).
    static func compute(derivedRoot: String, derived: [DerivedEntry], caches: [CacheInfo], watch: [String],
                        history: [HistoryPoint]) -> Growth? {
        let entries = load()
        guard let now = entries.last else { return nil }
        let base = entries.last(where: { now.t.timeIntervalSince($0.t) >= 20 * 3600 }) ?? entries.first!
        guard now.t.timeIntervalSince(base.t) >= 3600 else { return nil }

        func delta(_ path: String) -> Int64 { (now.sizes[path] ?? 0) - (base.sizes[path] ?? 0) }

        var items: [GrowthItem] = []
        let projects = derived
            .map { ($0.title, delta($0.path)) }
            .filter { $0.1 >= 100 * 1024 }
            .sorted { $0.1 > $1.1 }
        let xcodeDetail = projects.first.map { p in
            (base.sizes[derived.first { $0.title == p.0 }!.path] == nil ? "new: " : "mostly ")
                + "\(p.0) +\(human(kb: p.1))"
        }
        items.append(GrowthItem(name: "Xcode build caches", deltaKB: delta(derivedRoot), detail: xcodeDetail))
        items += caches.map { GrowthItem(name: $0.name, deltaKB: delta($0.path), detail: nil) }
        items += watch.map { GrowthItem(name: Paths.abbreviate($0), deltaKB: delta($0), detail: nil) }

        let tracked = items.reduce(Int64(0)) { $0 + $1.deltaKB }
        var untracked: Int64?
        if let fb = freeGB(at: base.t, history), let fn = freeGB(at: now.t, history) {
            let usedKB = Int64((fb - fn) * 1_048_576)
            untracked = usedKB - tracked
        }
        let shown = items.filter { abs($0.deltaKB) >= 50 * 1024 }.sorted { $0.deltaKB > $1.deltaKB }
        return Growth(since: base.t, items: Array(shown.prefix(6)), untrackedKB: untracked)
    }

    private static func freeGB(at t: Date, _ history: [HistoryPoint]) -> Double? {
        guard let p = history.min(by: { abs($0.t.timeIntervalSince(t)) < abs($1.t.timeIntervalSince(t)) }),
              abs(p.t.timeIntervalSince(t)) <= 20 * 60 else { return nil }
        return p.freeGB
    }
}

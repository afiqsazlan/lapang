import Foundation

// Pressure spikes: when memory pressure rises to warning or critical, or swap grows fast, which
// groups of processes grew the most in the ten minutes before it.

struct PressureSpike: Codable, Identifiable {
    enum Trigger: String, Codable { case warn, critical, swap }
    struct Culprit: Codable {
        let name: String
        let mb: Int
        /// Growth since `since`; nil when there was no earlier sample to compare with.
        let growthMB: Int?
    }

    let t: Date
    let trigger: Trigger
    let pressure: Int
    let swapGB: Double
    let swapGrowthGB: Double?
    let since: Date?
    let culprits: [Culprit]
    var id: Date { t }

    var summary: String {
        culprits.map { c in
            if let g = c.growthMB { return "\(c.name) +\(human(bytes: Int64(g) << 20))" }
            return "\(c.name) \(human(bytes: Int64(c.mb) << 20))"
        }.joined(separator: ", ")
    }
}

/// Footprints by group at one sample, in MB, groups of 50 MB or more.
struct GroupSample: Codable {
    let t: Date
    let mb: [String: Int]
}

enum PressureSpikes {
    static let window: TimeInterval = 10 * 60
    static let swapGrowthGB = 1.0
    static let minGrowthMB = 256

    private static let spikesFile = Paths.support + "/memory-spikes.json"
    private static let samplesFile = Paths.support + "/memory-groups.json"
    private static let lock = NSLock()

    /// Called with every memory sample. Only samples that were stored in the history count, so
    /// the app and the CLI can't both record the same spike.
    static func observe(_ p: MemoryPoint, previous: MemoryPoint?, stored: Bool, history: [MemoryPoint],
                        users: [MemoryUser]) -> [PressureSpike] {
        lock.lock(); defer { lock.unlock() }
        var spikes: [PressureSpike] = read(spikesFile) ?? []
        guard stored else { return spikes }
        var samples: [GroupSample] = read(samplesFile) ?? []
        let now = Dictionary(users.map { ($0.name, Int($0.bytes >> 20)) }, uniquingKeysWith: +).filter { $0.value >= 50 }
        if let spike = detect(p, previous: previous, history: history, recent: spikes, samples: samples, now: now) {
            spikes.append(spike)
            spikes.removeAll { p.t.timeIntervalSince($0.t) > 7 * 86400 }
            write(spikes, to: spikesFile)
        }
        samples.append(GroupSample(t: p.t, mb: now))
        samples.removeAll { p.t.timeIntervalSince($0.t) > 30 * 60 }
        write(samples, to: samplesFile)
        return spikes
    }

    static func label(_ s: PressureSpike) -> String {
        switch s.trigger {
        case .critical: return "critical"
        case .warn: return "under pressure"
        case .swap: return "swap +" + String(format: "%.1f GB", s.swapGrowthGB ?? 0)
        }
    }

    static func all() -> [PressureSpike] {
        lock.lock(); defer { lock.unlock() }
        return read(spikesFile) ?? []
    }

    static func detect(_ p: MemoryPoint, previous: MemoryPoint?, history: [MemoryPoint], recent: [PressureSpike],
                       samples: [GroupSample], now: [String: Int]) -> PressureSpike? {
        let swapBefore = closest(history.map { ($0.t, $0.swapGB) }, before: p.t)
        let swapGrowth = swapBefore.map { p.swapGB - $0 }
        guard let trigger = trigger(p, previous: previous, swapGrowth: swapGrowth, recent: recent) else { return nil }
        let base = closest(samples.map { ($0.t, $0) }, before: p.t)
        return PressureSpike(t: p.t, trigger: trigger, pressure: p.pressure, swapGB: p.swapGB,
                             swapGrowthGB: swapGrowth.map { ($0 * 10).rounded() / 10 },
                             since: base?.t, culprits: culprits(now, base: base?.mb))
    }

    /// Rising into warning or critical, or swap up a gigabyte in ten minutes. A warning or swap
    /// spike right after another spike is the same episode; rising to critical always counts.
    static func trigger(_ p: MemoryPoint, previous: MemoryPoint?, swapGrowth: Double?,
                        recent: [PressureSpike]) -> PressureSpike.Trigger? {
        let before = previous.flatMap { p.t.timeIntervalSince($0.t) <= 5 * 60 ? $0.pressure : nil }
        func quietSince(_ minutes: Double, _ kinds: Set<PressureSpike.Trigger>) -> Bool {
            !recent.contains { kinds.contains($0.trigger) && p.t.timeIntervalSince($0.t) < minutes * 60 }
        }
        if let before, p.pressure >= 4, before < 4, quietSince(10, [.critical]) { return .critical }
        if let before, p.pressure >= 2, before < 2, quietSince(10, [.warn, .critical, .swap]) { return .warn }
        if let g = swapGrowth, g >= swapGrowthGB, quietSince(15, [.warn, .critical, .swap]) { return .swap }
        return nil
    }

    /// Whatever grew the most since the baseline; the biggest groups when nothing grew much or
    /// there's no baseline yet.
    static func culprits(_ now: [String: Int], base: [String: Int]?) -> [PressureSpike.Culprit] {
        if let base {
            let grown = now.map { (name: $0.key, mb: $0.value, growth: $0.value - (base[$0.key] ?? 0)) }
                .filter { $0.growth >= minGrowthMB }
                .sorted { $0.growth > $1.growth }
                .prefix(3)
            if !grown.isEmpty { return grown.map { .init(name: $0.name, mb: $0.mb, growthMB: $0.growth) } }
        }
        return now.sorted { $0.value > $1.value }.prefix(3).map { name, mb in
            .init(name: name, mb: mb, growthMB: base.map { mb - ($0[name] ?? 0) })
        }
    }

    /// The value nearest `window` before `t`, taken 3 to 20 minutes before it.
    private static func closest<V>(_ items: [(Date, V)], before t: Date) -> V? {
        let target = t.addingTimeInterval(-window)
        return items
            .filter { t.timeIntervalSince($0.0) >= 3 * 60 && t.timeIntervalSince($0.0) <= 20 * 60 }
            .min { abs($0.0.timeIntervalSince(target)) < abs($1.0.timeIntervalSince(target)) }?.1
    }

    private static func read<T: Decodable>(_ file: String) -> T? {
        guard let d = FileManager.default.contents(atPath: file) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(T.self, from: d)
    }

    private static func write<T: Encodable>(_ value: T, to file: String) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(value) { try? d.write(to: URL(fileURLWithPath: file)) }
    }
}

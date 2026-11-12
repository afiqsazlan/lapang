import Darwin
import Foundation

// A record of what Lapang did, one JSON object per line in Application Support/Lapang/actions.log,
// so you can later see what was deleted, killed or shut down, from where, and what it freed.
// It stays on this Mac; nothing is sent anywhere.

struct ActionEntry: Codable {
    let time: Date
    /// `panel` (menu bar or window) or `cli`.
    let source: String
    let action: String
    /// A few words for the menu and `lapang log`, e.g. the project or process name.
    let title: String
    /// Everything needed to identify what was acted on: paths, pid, udid, bundle.
    let target: [String: String]
    /// `ok`, or what went wrong.
    let result: String
    var diskFreedBytes: Int64?
    var memoryFreedBytes: Int64?
    /// Set when the action was one item of a bulk run ("clean all", "clean").
    var batch: String?
    let version: String
}

enum ActionLog {
    static let file = Paths.support + "/actions.log"
    static let keepDays = 30

    /// Set once at startup; the CLI switches it to `cli` before running a command.
    nonisolated(unsafe) static var source = "panel"

    /// Tags every entry recorded inside `withValue` as one item of a bulk run.
    @TaskLocal static var batch: String?

    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    static func record(_ action: String, title: String, target: [String: String], result: String?,
                       diskFreed: Int64? = nil, memoryFreed: Int64? = nil) {
        let e = ActionEntry(time: Date(), source: source, action: action, title: title,
                            target: target.filter { !$0.value.isEmpty }, result: result ?? "ok",
                            diskFreedBytes: diskFreed, memoryFreedBytes: memoryFreed, batch: batch, version: version)
        append(e)
    }

    /// Newest first.
    static func recent(_ limit: Int? = nil) -> [ActionEntry] {
        guard let d = FileManager.default.contents(atPath: file) else { return [] }
        let all = Array(decode(d).reversed())
        return limit.map { Array(all.prefix($0)) } ?? all
    }

    // The app and the CLI can both write at once, so appending and pruning happen under a file lock.
    private static func append(_ e: ActionEntry) {
        let fd = open(file, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let existing = (try? h.readToEnd()) ?? Data()
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86400)
        var lines = existing.split(separator: UInt8(ascii: "\n")).filter { line in
            guard let t = try? decoder.decode(TimeOnly.self, from: Data(line)).time else { return false }
            return t >= cutoff
        }
        guard let new = try? encoder.encode(e) else { return }
        lines.append(new[...])
        var out = Data()
        for l in lines { out.append(contentsOf: l); out.append(UInt8(ascii: "\n")) }
        ftruncate(fd, 0)
        try? h.seek(toOffset: 0)
        try? h.write(contentsOf: out)
    }

    private struct TimeOnly: Decodable { let time: Date }

    private static func decode(_ d: Data) -> [ActionEntry] {
        d.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(ActionEntry.self, from: Data($0)) }
    }

    static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return enc
    }()

    private static let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()
}

extension ActionEntry {
    /// "14:02 · Delete build cache · old/my-app · ok, 2.1 GB" for the gear menu.
    var line: String {
        let when = Calendar.current.isDateInToday(time)
            ? time.formatted(date: .omitted, time: .shortened)
            : time.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        // a menu grows to fit its longest item, so a long error message is cut short here
        let result = outcome.count > 40 ? outcome.prefix(39) + "…" : outcome
        return [when, action.prefix(1).uppercased() + action.dropFirst(), title, result].joined(separator: " · ")
    }

    var outcome: String {
        guard result == "ok" else { return result }
        var freed: [String] = []
        if let d = diskFreedBytes, d > 0 { freed.append(human(bytes: d)) }
        if let m = memoryFreedBytes, m > 0 { freed.append(human(bytes: m) + " RAM") }
        return freed.isEmpty ? "ok" : "ok, " + freed.joined(separator: " + ")
    }
}

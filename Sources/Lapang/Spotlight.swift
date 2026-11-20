import Foundation

// Spotlight indexing dev folders. A tree of git worktrees is millions of small files that change all
// day; mds_stores reads them back in endlessly and saturates the disk. Lapang finds large dev folders
// Spotlight still indexes and says how to exclude them. It never changes Spotlight's settings itself.

struct IndexedFolder: Codable, Identifiable {
    let path: String
    let kb: Int64
    /// Items Spotlight has indexed in it (from mdfind).
    let items: Int
    var id: String { path }
}

struct SpotlightReport {
    var folders: [IndexedFolder]
    var measuredAt: Date?
    /// Indexing is off for the data volume altogether.
    var indexingOff = false

    static let howTo = "Add the folder in System Settings › Spotlight › Search Privacy (drag it into the list), "
        + "or put an empty .metadata_never_index file in it. Lapang never changes this for you."

    /// The commands someone could run themselves; the Privacy list is the reliable way.
    static func excludeCommand(_ path: String) -> String {
        "touch '\(path.replacingOccurrences(of: "'", with: "'\\''"))/.metadata_never_index'"
    }
}

enum Spotlight {
    private struct Stored: Codable { let measuredAt: Date; let roots: [String]; let folders: [IndexedFolder] }
    private static let file = Paths.support + "/spotlight.json"
    static let maxAge: TimeInterval = 6 * 3600

    /// The configured dev roots, else the usual dev folders that exist, plus worktree repos and roots.
    static func roots(_ config: Config) -> [String] {
        var out = config.spotlight.roots.map(Paths.expand)
        if out.isEmpty {
            out = ["~/Developer", "~/Sites", "~/Projects", "~/projects", "~/code", "~/Code", "~/src", "~/dev", "~/work",
                   "~/repos", "~/git", "~/GitHub"].map(Paths.expand)
                .filter { FileManager.default.fileExists(atPath: $0) }
        }
        out += (config.worktrees.repos + config.worktrees.roots).map { Paths.expand($0.path) }
        var seen = Set<String>()
        return out.filter { seen.insert(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path).inserted }
    }

    /// What the last check found, if it's recent and for the same roots.
    static func cached(_ config: Config) -> SpotlightReport? {
        guard let d = FileManager.default.contents(atPath: file),
              let s = try? JSONDecoder().decode(Stored.self, from: d), s.roots == roots(config) else { return nil }
        return SpotlightReport(folders: s.folders.filter { $0.kb >= minKB(config) }, measuredAt: s.measuredAt)
    }

    static func isDue(_ config: Config) -> Bool {
        guard let r = cached(config), let t = r.measuredAt else { return true }
        return Date().timeIntervalSince(t) > maxAge
    }

    private static func minKB(_ config: Config) -> Int64 { Int64(config.spotlight.minGB * 1_048_576) }

    /// Checks every folder one level under each root (and each root itself) and measures the indexed
    /// ones. Slow (du over the whole tree, at low priority): call off the main thread.
    static func check(_ config: Config) -> SpotlightReport {
        let rs = roots(config)
        if Shell.run("/usr/bin/mdutil", ["-s", "/System/Volumes/Data"])?.text.contains("disabled") == true {
            return SpotlightReport(folders: [], measuredAt: Date(), indexingOff: true)
        }
        let fm = FileManager.default
        var candidates: [String] = []
        for root in rs {
            candidates.append(root)
            for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                let p = root + "/" + name
                var dir: ObjCBool = false
                if fm.fileExists(atPath: p, isDirectory: &dir), dir.boolValue { candidates.append(p) }
            }
        }
        var found: [IndexedFolder] = []
        for p in candidates where !excludedByMarker(p) {
            let items = indexedItems(p)
            guard items > 0 else { continue }
            // a root with indexed children is reported through them, not twice
            if rs.contains(p), candidates.contains(where: { $0.hasPrefix(p + "/") }) { continue }
            if let kb = SizeStore.du(p) { found.append(IndexedFolder(path: p, kb: kb, items: items)) }
        }
        found.sort { $0.kb > $1.kb }
        let now = Date()
        if let d = try? JSONEncoder().encode(Stored(measuredAt: now, roots: rs, folders: found)) {
            try? d.write(to: URL(fileURLWithPath: file), options: .atomic)
        }
        return SpotlightReport(folders: found.filter { $0.kb >= minKB(config) }, measuredAt: now)
    }

    /// A `.metadata_never_index` file in it or above it, or a folder name ending in `.noindex`.
    static func excludedByMarker(_ path: String) -> Bool {
        var url = URL(fileURLWithPath: path)
        while url.path != "/" && url.path != Paths.home {
            if url.lastPathComponent.hasSuffix(".noindex") { return true }
            if FileManager.default.fileExists(atPath: url.path + "/.metadata_never_index") { return true }
            url.deleteLastPathComponent()
        }
        return false
    }

    /// How many items Spotlight's index holds under the folder; 0 when it's excluded.
    static func indexedItems(_ path: String) -> Int {
        guard let r = Shell.run("/usr/bin/mdfind", ["-count", "-onlyin", path, "kMDItemContentTypeTree == \"public.item\""])
        else { return 0 }
        return Int(r.text) ?? 0
    }
}

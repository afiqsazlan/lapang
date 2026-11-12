import CryptoKit
import Darwin
import Foundation
import Sparkle
import SystemConfiguration

// `lapang report` and "Report an issue…": one Markdown file of diagnostics to attach to a GitHub
// issue by hand. It is written to disk and nothing else: Lapang sends nothing anywhere. Your user
// name, host names and the folder names under your home folder are redacted unless --full is given.

enum Report {
    static let issuesURL = "https://github.com/afiqsazlan/lapang/issues/new"

    struct Output {
        let markdown: String
        /// "Lapang 0.1.0 (1) · Sparkle 2.10.1 · macOS 15.6 (24G84) · Apple M1 Pro, 16 GB"
        let versions: String
        /// Redacted like the file.
        let problemLines: [String]
        /// What the file holds, one short phrase per part, for the CLI to show before you share it.
        let contents: [String]
        var problems: Int { problemLines.count }

        /// For --copy: pasted into an issue body, with the file attached by hand.
        func clipboard(file: String) -> String {
            var lines = ["**Lapang diagnostics**", "", versions, ""]
            lines += problemLines.isEmpty ? ["No recent problems found."] : ["Recent problems:"] + problemLines.map { "- " + $0 }
            lines += ["", "Full report: \((file as NSString).lastPathComponent) (attached)"]
            return lines.joined(separator: "\n")
        }
    }

    static func make(_ s: Snapshot, full: Bool, logLimit: Int = 20) -> Output {
        let r = Redactor(enabled: !full)

        // Everything that can carry a name, as JSON, so the redactor sees all of it before redacting any of it.
        var status = CLI.jsonObject(s)
        let configText = FileManager.default.contents(atPath: Config.path).map { String(decoding: $0, as: UTF8.self) }
        let configJSON = configText.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
        let entries = ActionLog.recent(logLimit)
        let failed = ActionLog.recent().filter { $0.result != "ok" }.prefix(10)
        var log = entries.compactMap(entryJSON)
        var failedJSON = failed.compactMap(entryJSON)

        if r.enabled {
            r.register(s.derived.flatMap { $0.title.split(separator: "/").map(String.init) })
            r.register(s.worktrees.flatMap { u in [u.group, u.name] + u.branches.filter { !Redactor.commonBranches.contains($0) } })
            r.register((s.sims ?? []).flatMap { $0.usage.apps.flatMap { [$0.name, $0.bundleID] } })
            r.register(s.procs.compactMap(\.session))
            r.register(s.ports.compactMap(\.label))
            r.register(s.sections.map(\.config.title))
            if let c = configJSON as? [String: Any] {
                r.register(((c["ports"] as? [String: Any])?["names"] as? [String: Any])?.values.compactMap { $0 as? String } ?? [])
                r.register((c["xcode"] as? [String: Any])?["protect"] as? [String] ?? [])
                r.register((c["sections"] as? [[String: Any]])?.compactMap { $0["title"] as? String } ?? [])
            }
            // A custom section's rows are whatever its script prints; keep how many there were.
            if var secs = status["sections"] as? [[String: Any]] {
                for i in secs.indices { secs[i]["rows"] = "\((secs[i]["rows"] as? [Any])?.count ?? 0) rows, hidden" }
                status["sections"] = secs
            }
            // Titles are free text ("old/my-app"); hash any the path pass can't account for.
            log = log.map(r.hidingTitle)
            failedJSON = failedJSON.map(r.hidingTitle)
            for v in [status, configJSON ?? [:], log, failedJSON] as [Any] { r.prime(v) }
        }

        let env = Environment.current
        var md: [String] = []
        md.append("# Lapang diagnostics")
        md.append("")
        md.append("Made by `lapang report` on \(stamp("yyyy-MM-dd HH:mm ZZZZZ")). "
            + "Nothing was sent anywhere; this file only goes where you attach it.")
        md.append(full
            ? "Not redacted (`--full`): paths, folder names, your user name and host name appear as they are."
            : "Redacted: your user name, host names, and folder names under your home folder, shown as hashes like ‹3fa2c1›. "
            + "The same name always gets the same hash within this file. Custom sections' rows are left out.")

        // Versions
        md.append("")
        md.append("## Versions")
        md.append("")
        md.append("- Lapang: \(CLI.versionString) (\(env.buildKind))")
        md.append("- Sparkle: \(env.sparkle)")
        md.append("- macOS: \(env.macOS)")
        md.append("- Mac: \(env.chip) · \(env.model) · \(env.cores) cores · \(human(bytes: Int64(env.memory))) memory")
        md.append("- Process: \(env.arch)")
        md.append("- Running from: `\(r.text(env.executable))`")
        md.append("- Disk: \(String(format: "%.0f GB free of %.0f GB", s.freeGB, s.totalGB))")

        // Problems
        var problems: [String] = []
        if let e = s.configError { problems.append("Config: " + r.text(e)) }
        for sec in s.sections where sec.error != nil {
            problems.append("Section \(r.text(sec.config.title)): " + r.text(sec.error ?? ""))
        }
        for e in failedJSON {
            problems.append("Action failed \(e["time"] as? String ?? ""): \(e["action"] as? String ?? "") · "
                + "\(r.text(e["title"] as? String ?? "")) · \(r.text(e["result"] as? String ?? ""))")
        }
        let crashes = crashReports()
        for c in crashes.prefix(5) {
            problems.append("Crash report \(c.name) (\(c.date.formatted(date: .abbreviated, time: .shortened)))")
        }
        md.append("")
        md.append("## Recent problems")
        md.append("")
        md.append(problems.isEmpty ? "None found: the config reads fine, no section errors, no failed actions in the last \(ActionLog.keepDays) days, no crash reports."
            : problems.map { "- " + $0 }.joined(separator: "\n"))
        if !crashes.isEmpty {
            md.append("")
            md.append("Crash reports are in ~/Library/Logs/DiagnosticReports. They aren't redacted, so read one before attaching it.")
        }

        // Data folder
        let files = dataFiles()
        md.append("")
        md.append("## Data folder")
        md.append("")
        md.append("~/Library/Application Support/Lapang, \(human(bytes: files.reduce(0) { $0 + $1.bytes })) in \(files.count) files:")
        md.append("")
        md.append("| File | Size | Modified |")
        md.append("|---|---|---|")
        for f in files {
            md.append("| \(f.name) | \(human(bytes: f.bytes)) | \(f.modified.formatted(date: .abbreviated, time: .shortened)) |")
        }

        // Config
        md.append("")
        md.append("## Config")
        md.append("")
        if let configText {
            md.append("~/.config/lapang/config.json:")
            md.append("")
            md.append("```json")
            if let configJSON {
                md.append(pretty(r.json(configJSON)))
            } else {
                md.append(r.text(configText).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            md.append("```")
        } else {
            md.append("No config.json; the defaults are in use.")
        }

        // Action log
        md.append("")
        md.append("## Recent actions")
        md.append("")
        if log.isEmpty {
            md.append("None in the last \(ActionLog.keepDays) days.")
        } else {
            md.append("The last \(log.count), newest first, as stored in actions.log:")
            md.append("")
            md.append("```json")
            for e in log { md.append(compact(r.json(e))) }
            md.append("```")
        }

        // Status
        md.append("")
        md.append("## Status")
        md.append("")
        md.append("`lapang status --json` at the time of this report:")
        md.append("")
        md.append("```json")
        md.append(pretty(r.json(status)))
        md.append("```")
        md.append("")

        let contents = [
            "versions (Lapang, Sparkle, macOS, chip)",
            problems.isEmpty ? "recent problems (none)" : "recent problems (\(problems.count))",
            "data folder file sizes (\(files.count))",
            configText == nil ? "config (none)" : "config.json",
            "last \(log.count) actions",
            "a status snapshot",
        ]
        let versions = "Lapang \(CLI.versionString) · Sparkle \(env.sparkle) · \(env.macOS) · \(env.chip), \(human(bytes: Int64(env.memory)))"
        return Output(markdown: md.joined(separator: "\n"), versions: versions, problemLines: problems, contents: contents)
    }

    /// Writes the report and returns its path. `out` is a file, or a folder to put it in; ~/Desktop by default.
    static func write(_ o: Output, to out: String? = nil) throws -> String {
        let name = "lapang-report-\(stamp("yyyy-MM-dd-HHmm")).md"
        var path = Paths.home + "/Desktop/" + name
        if let out {
            let p = (Paths.expand(out) as NSString).standardizingPath
            var dir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &dir), dir.boolValue || out.hasSuffix("/") {
                path = p + "/" + name
            } else {
                path = p
            }
        }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(o.markdown.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// The new-issue page with a short prefilled body; the report file is attached by hand.
    static func issueURL(_ o: Output, file: String) -> URL {
        let body = """
        ### What happened?



        ### What did you expect?



        ---
        \(o.versions)
        Recent problems found: \(o.problems == 0 ? "none" : "\(o.problems)")
        Diagnostics: drag \((file as NSString).lastPathComponent) here (read it first; it's on your \(file.hasPrefix(Paths.home + "/Desktop/") ? "Desktop" : "Mac")).
        """
        var c = URLComponents(string: issuesURL)!
        c.queryItems = [URLQueryItem(name: "body", value: body)]
        return c.url!
    }

    // MARK: parts

    struct Environment {
        let buildKind, sparkle, macOS, chip, model, arch, executable: String
        let cores: Int
        let memory: UInt64

        static var current: Environment {
            let info = ProcessInfo.processInfo
            let v = info.operatingSystemVersion
            let build = sysctlString("kern.osversion").map { " (\($0))" } ?? ""
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = sysctlInt("sysctl.proc_translated") == 1 ? "x86_64 under Rosetta" : "x86_64"
            #endif
            let sparkleBundle = Bundle(for: SPUUpdater.self)
            return Environment(
                buildKind: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil ? "release build" : "built from source",
                sparkle: sparkleBundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                macOS: "macOS \(v.majorVersion).\(v.minorVersion)\(v.patchVersion > 0 ? ".\(v.patchVersion)" : "")\(build)",
                chip: sysctlString("machdep.cpu.brand_string") ?? "unknown chip",
                model: sysctlString("hw.model") ?? "unknown model",
                arch: arch,
                executable: Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0],
                cores: info.processorCount,
                memory: info.physicalMemory)
        }

        static func sysctlString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buf = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
            return String(cString: buf)
        }

        static func sysctlInt(_ name: String) -> Int32? {
            var v: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : nil
        }
    }

    struct FileInfo { let name: String; let bytes: Int64; let modified: Date }

    /// Every file in the data folder, by path inside it, largest first.
    static func dataFiles() -> [FileInfo] {
        let root = URL(fileURLWithPath: Paths.support)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var out: [FileInfo] = []
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            out.append(FileInfo(name: String(url.path.dropFirst(root.path.count + 1)), bytes: Int64(v.fileSize ?? 0),
                                modified: v.contentModificationDate ?? .distantPast))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    struct Crash { let name: String; let date: Date }

    /// Lapang's crash reports from the last 30 days, newest first.
    static func crashReports() -> [Crash] {
        let fm = FileManager.default
        let dirs = [Paths.home + "/Library/Logs/DiagnosticReports", Paths.home + "/Library/Logs/DiagnosticReports/Retired"]
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        return dirs.flatMap { dir in
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("Lapang") }.compactMap { name -> Crash? in
                guard let d = (try? fm.attributesOfItem(atPath: dir + "/" + name))?[.modificationDate] as? Date, d >= cutoff else { return nil }
                return Crash(name: name, date: d)
            }
        }.sorted { $0.date > $1.date }
    }

    static func stamp(_ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: Date())
    }

    static func entryJSON(_ e: ActionEntry) -> [String: Any]? {
        (try? ActionLog.encoder.encode(e)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func pretty(_ v: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\(v)"
    }

    static func compact(_ v: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\(v)"
    }
}

// MARK: - Redaction

/// Hides who and what is on this Mac while keeping the report useful: the same name always becomes
/// the same short hash (salted per report, so a hash can't be looked up), so you can still tell that
/// two paths point into one project.
final class Redactor {
    let enabled: Bool
    private let salt = UUID().uuidString
    private let home = Paths.home
    /// User and host names, longest first, each with what it becomes.
    private let fixed: [(NSRegularExpression, String)]
    /// Names learned from paths and the snapshot: project, folder, branch and app names.
    private var names: [String: String] = [:]
    private var pattern: NSRegularExpression?

    init(enabled: Bool) {
        self.enabled = enabled
        var f: [(String, String)] = []
        for h in Self.hostNames() { f.append((h, "‹host›")) }
        let user = NSUserName()
        if user.count >= 2 { f.append((user, "‹user›")) }
        for part in NSFullUserName().split(separator: " ") where part.count >= 3 { f.append((String(part), "‹user›")) }
        fixed = f.sorted { $0.0.count > $1.0.count }.compactMap { name, mark in
            (try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![\p{L}\p{N}])"#,
                                      options: .caseInsensitive)).map { ($0, mark) }
        }
    }

    static let commonBranches: Set<String> = ["main", "master", "dev", "develop", "development", "trunk", "HEAD", "staging", "release"]

    /// Folder names that say nothing about you: system folders, tool caches, build output.
    static let generic: Set<String> = [
        "library", "application support", "caches", "logs", "preferences", "containers", "group containers",
        "developer", "xcode", "deriveddata", "coresimulator", "devices", "data", "bundle", "application",
        "desktop", "documents", "downloads", "applications", "movies", "music", "pictures", "public",
        ".config", "lapang", ".local", "bin", "share", "lib", "state", ".cache", ".pub-cache", ".gradle", ".npm",
        ".yarn", ".pnpm-store", ".cargo", ".rustup", ".m2", ".cocoapods", ".swiftpm", ".android", ".dart_tool",
        ".build", "build", "node_modules", "pods", ".git", ".worktrees", "worktrees", "sites", "projects", "code",
        "dev", "src", "repos", "work", "workspace", "go", "pkg", "tmp", "ios", "android", "macos", "web",
        "ios devicesupport", "archives", "products", "intermediates.noindex", "index.noindex", "sourcepackages",
        "shares", "actions.log", "flutter", "sdk", "sdks", ".claude", "simulator", "debug", "release",
        "arm64-apple-macosx", "x86_64-apple-macosx",
    ]

    static func hostNames() -> [String] {
        var names: [String] = []
        if let c = SCDynamicStoreCopyComputerName(nil, nil) as String? { names.append(c) }
        if let l = SCDynamicStoreCopyLocalHostName(nil) as String? { names += [l + ".local", l] }
        var buf = [CChar](repeating: 0, count: 256)
        if gethostname(&buf, buf.count) == 0 {
            let h = String(cString: buf)
            names += [h, h.components(separatedBy: ".").first ?? h]
        }
        return Array(Set(names.filter { $0.count >= 3 }))
    }

    func hash(_ s: String) -> String {
        let d = SHA256.hash(data: Data((salt + s).utf8))
        return "‹" + d.prefix(3).map { String(format: "%02x", $0) }.joined() + "›"
    }

    /// Names to hide wherever they appear, besides the folder names found in paths.
    func register(_ list: [String]) {
        for n in list where n.count >= 3 && !Self.generic.contains(n.lowercased()) && names[n] == nil {
            names[n] = hash(n)
        }
        pattern = nil
    }

    /// Walks a value once to learn every folder name in it, so text redacted before a path is seen still loses it.
    func prime(_ v: Any) { _ = json(v) }

    func json(_ v: Any) -> Any {
        guard enabled else { return v }
        switch v {
        case let d as [String: Any]: return d.mapValues { json($0) }
        case let a as [Any]: return a.map { json($0) }
        case let s as String: return text(s)
        default: return v
        }
    }

    /// An action log entry with its title hashed when nothing else would hide it.
    func hidingTitle(_ e: [String: Any]) -> [String: Any] {
        var e = e
        if let t = e["title"] as? String {
            if let target = e["target"] as? [String: Any] {
                for case let p as String in target.values { _ = text(p) }
            }
            let shown = text(t)
            e["title"] = shown == t && !t.isEmpty && !Self.generic.contains(t.lowercased()) ? hash(t) : shown
        }
        return e
    }

    func text(_ input: String) -> String {
        guard enabled, !input.isEmpty else { return input }
        var s = input
        if s == home { s = "~" }
        s = s.replacingOccurrences(of: home + "/", with: "~/")
        s = s.replacingOccurrences(of: home, with: "~")
        s = paths(in: s)
        for (re, mark) in fixed {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: NSRegularExpression.escapedTemplate(for: mark))
        }
        return learned(in: s)
    }

    /// Hashes each folder name in ~/… and /Volumes/… paths that isn't generic, remembering it.
    private func paths(in s: String) -> String {
        // a whole string that is a path may have spaces in it; a path inside text ends at one
        let whole = (s.hasPrefix("~/") || s.hasPrefix("/Volumes/")) && !s.contains("\n")
        let re = try! NSRegularExpression(pattern: whole ? #"^.*$"# : #"(~|/Volumes)(/[^\s"'`,;()\[\]{}<>|]+)+"#)
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: s) else { continue }
            out.replaceSubrange(r, with: path(String(s[r])))
        }
        return out
    }

    private func path(_ p: String) -> String {
        var parts = p.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first else { return p }
        var start = 1
        if first.isEmpty, parts.count > 2, parts[1] == "Volumes" {
            parts[2] = component(parts[2], force: true)
            start = 3
        } else if first != "~" {
            return p
        }
        // Lapang's own folders hold only its own files
        let own = p.hasPrefix("~/Library/Application Support/Lapang") || p.hasPrefix("~/.config/lapang")
        // ~/Library holds other apps' folders, named by those apps; only build caches and
        // simulator app bundles there are named after your projects
        let library = start == 1 && parts.count > 1 && parts[1] == "Library"
        for i in start..<parts.count where !own {
            if library {
                let mine = parts[i - 1] == "DerivedData" || (parts[i].hasSuffix(".app") && p.contains("/CoreSimulator/"))
                if mine { parts[i] = component(parts[i]) }
            } else if i == 1 && parts[i].hasPrefix(".") {
                continue  // a tool's dot-folder: ~/.nvm, ~/.docker
            } else {
                parts[i] = component(parts[i])
            }
        }
        return parts.joined(separator: "/")
    }

    private func component(_ c: String, force: Bool = false) -> String {
        if c.isEmpty || c.hasPrefix("‹") { return c }
        if !force && (Self.generic.contains(c.lowercased()) || Self.isOpaqueID(c)) { return c }
        // DerivedData folders are "<project>-<28 letters>"
        if let dash = c.lastIndex(of: "-"), c.distance(from: dash, to: c.endIndex) == 29 {
            register([String(c[..<dash])])
        }
        let ext = (c as NSString).pathExtension
        let keepExt = ["app", "xcodeproj", "xcworkspace", "json", "log", "png", "md", "swift", "dart", "yaml"].contains(ext)
        let base = keepExt ? (c as NSString).deletingPathExtension : c
        if names[base] == nil, base.count >= 3 { register([base]) }
        return (names[base] ?? hash(base)) + (keepExt ? "." + ext : "")
    }

    /// UUIDs, hex ids and numbers: they identify nothing outside this Mac.
    static func isOpaqueID(_ c: String) -> Bool {
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        return c.count >= 8 && c.unicodeScalars.allSatisfy(hex.contains) || c.allSatisfy(\.isNumber)
    }

    /// Replaces every learned name standing on its own (not inside a longer word).
    private func learned(in s: String) -> String {
        guard !names.isEmpty else { return s }
        if pattern == nil {
            let alts = names.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
            pattern = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])("# + alts.joined(separator: "|") + #")(?![\p{L}\p{N}_])"#)
        }
        guard let re = pattern else { return s }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: s), let h = names[String(s[r])] else { continue }
            out.replaceSubrange(r, with: h)
        }
        return out
    }
}

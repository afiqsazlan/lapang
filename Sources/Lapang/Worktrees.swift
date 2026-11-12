import Foundation

// Git worktrees: parallel checkouts are cheap to make and easy to forget, and each one grows its
// own build output (build/, .dart_tool/, node_modules/, vendor/, Pods …). Lapang lists them from
// the repos and roots in config.json with that output's size, when each was last touched, and
// whether its branch is merged, so the forgotten ones can be cleaned or removed.

/// One git worktree.
struct Worktree {
    let path: String
    let repo: String
    let branch: String?  // nil when detached
    let merged: Bool
    /// The branch was created and never committed to, so "merged" says nothing.
    let noCommits: Bool
    let lastActivity: Date
    /// Git-ignored, regenerable folders inside it.
    let outputs: [String]
}

/// A row in the panel: a repo's worktree, or a folder under a root holding worktrees of several repos.
struct WorktreeUnit: Identifiable {
    let path: String
    let group: String
    let members: [Worktree]
    /// Output folders of the unit itself, outside any member (a root unit's shared build/).
    let ownOutputs: [String]
    let removeCommand: String
    /// The repo, for {repo} in removeCommand; nil for a root unit.
    let repo: String?
    var agentOpen = false
    var id: String { path }

    var name: String { (path as NSString).lastPathComponent }
    var outputs: [String] { members.flatMap(\.outputs) + ownOutputs }
    var branches: [String] { members.compactMap(\.branch) }
    var merged: Bool { !members.isEmpty && members.allSatisfy { $0.merged && !$0.noCommits } }
    var noCommits: Bool { !members.isEmpty && members.allSatisfy(\.noCommits) }
    var lastActivity: Date { members.map(\.lastActivity).max() ?? .distantPast }
    var idleDays: Int { max(0, Int(Date().timeIntervalSince(lastActivity) / 86400)) }
    var outputKB: Int64? { WorktreeSizes.shared.total(outputs) }

    /// Output size by folder kind, largest first: [("build", kb), (".dart_tool", kb)].
    var breakdown: [(name: String, kb: Int64)] {
        var by: [String: Int64] = [:]
        for o in outputs {
            guard let kb = WorktreeSizes.shared.kb(o) else { continue }
            by[(o as NSString).lastPathComponent, default: 0] += kb
        }
        return by.map { ($0.key, $0.value) }.sorted { $0.kb > $1.kb }
    }

    /// node_modules and vendor are often copy-on-write clones, which du counts in full.
    var hasClonableOutput: Bool { outputs.contains { ["node_modules", "vendor"].contains(($0 as NSString).lastPathComponent) } }
}

enum WorktreeScan {
    /// Folder names that are always safe to delete and rebuild, when git ignores them.
    static let outputNames: Set<String> = ["build", ".dart_tool", "node_modules", "vendor", ".next", "dist", "target", "Pods"]

    static func units(_ cfg: Config.Worktrees) -> [WorktreeUnit] {
        var infos: [String: RepoInfo] = [:]
        func info(_ repo: String, base: String?) -> RepoInfo {
            if let i = infos[repo] { return i }
            let i = RepoInfo(repo: repo, base: base)
            infos[repo] = i
            return i
        }
        // first the cheap part, deciding what the units are; then each worktree's git calls and
        // folder walk, several at once
        struct Job { let path: String; let branch: String?; let info: RepoInfo }
        struct Pending { let path: String; let group: String; let jobs: [Job]; let own: [String]; let remove: String; let repo: String? }
        let roots = cfg.roots.map { Paths.expand($0.path) }
        var pending: [Pending] = []

        for src in cfg.repos {
            let repo = Paths.expand(src.path)
            let title = src.title ?? (repo as NSString).lastPathComponent
            let ri = info(repo, base: src.base)
            for e in listWorktrees(repo).dropFirst() where !e.prunable {
                // worktrees under a root are listed there, with their siblings
                guard !roots.contains(where: { e.path.hasPrefix($0 + "/") }) else { continue }
                pending.append(Pending(path: e.path, group: title, jobs: [Job(path: e.path, branch: e.branch, info: ri)],
                                       own: [], remove: src.removeCommand ?? cfg.removeCommand, repo: repo))
            }
        }
        for src in cfg.roots {
            let root = Paths.expand(src.path)
            let title = src.title ?? (root as NSString).lastPathComponent
            for dir in subfolders(root) {
                var jobs: [Job] = []
                for sub in subfolders(dir) {
                    guard let gitdir = gitdirOf(sub), let r = gitdir.range(of: "/.git/worktrees/") else { continue }
                    jobs.append(Job(path: sub, branch: branchIn(gitdir), info: info(String(gitdir[..<r.lowerBound]), base: src.base)))
                }
                let memberPaths = Set(jobs.map(\.path))
                let own = subfolders(dir).filter { outputNames.contains(($0 as NSString).lastPathComponent) && !memberPaths.contains($0) }
                guard !jobs.isEmpty || !own.isEmpty else { continue }
                pending.append(Pending(path: dir, group: title, jobs: jobs, own: own,
                                       remove: src.removeCommand ?? cfg.removeCommand, repo: nil))
            }
        }

        let jobs = pending.flatMap(\.jobs)
        var done = [Worktree?](repeating: nil, count: jobs.count)
        var own = [[String]](repeating: [], count: pending.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: jobs.count + pending.count) { i in
            if i < jobs.count {
                let w = worktree(jobs[i].path, branch: jobs[i].branch, jobs[i].info)
                lock.lock(); done[i] = w; lock.unlock()
            } else {
                let p = pending[i - jobs.count]
                let o = ignoredOrLoose(p.own, in: p.path)
                lock.lock(); own[i - jobs.count] = o; lock.unlock()
            }
        }
        var i = 0
        return pending.enumerated().map { k, p in
            let members = done[i ..< i + p.jobs.count].compactMap { $0 }
            i += p.jobs.count
            return WorktreeUnit(path: p.path, group: p.group, members: members, ownOutputs: own[k],
                                removeCommand: p.remove, repo: p.repo)
        }
    }

    // MARK: git

    struct ListEntry { var path = ""; var branch: String?; var prunable = false }

    static func listWorktrees(_ repo: String) -> [ListEntry] {
        guard let r = git(repo, ["worktree", "list", "--porcelain"]), r.status == 0 else { return [] }
        var out: [ListEntry] = []
        var cur: ListEntry?
        for line in r.text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                if let c = cur { out.append(c) }
                cur = ListEntry(path: String(line.dropFirst(9)))
            } else if line.hasPrefix("branch refs/heads/") {
                cur?.branch = String(line.dropFirst(18))
            } else if line.hasPrefix("prunable") {
                cur?.prunable = true
            }
        }
        if let c = cur { out.append(c) }
        return out
    }

    /// What's known about a repo's branches, read once per scan.
    struct RepoInfo {
        let commonDir: String
        let merged: Set<String>
        let commitDates: [String: Date]

        init(repo: String, base: String?) {
            let dir = WorktreeScan.git(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"])?.text ?? ""
            commonDir = dir.isEmpty ? repo + "/.git" : dir
            var b = base
            if b == nil, let r = WorktreeScan.git(repo, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]), r.status == 0 {
                b = r.text
            }
            if b == nil {
                b = ["main", "master"].first { WorktreeScan.git(repo, ["rev-parse", "--verify", "--quiet", $0])?.status == 0 }
            }
            if let b, let r = WorktreeScan.git(repo, ["for-each-ref", "--merged", b, "--format=%(refname:short)", "refs/heads"]) {
                merged = Set(r.text.split(separator: "\n").map(String.init))
            } else {
                merged = []
            }
            var dates: [String: Date] = [:]
            if let r = WorktreeScan.git(repo, ["for-each-ref", "--format=%(refname:short)\t%(committerdate:unix)", "refs/heads"]) {
                for line in r.text.split(separator: "\n") {
                    let parts = line.split(separator: "\t")
                    if parts.count == 2, let t = Double(parts[1]) { dates[String(parts[0])] = Date(timeIntervalSince1970: t) }
                }
            }
            commitDates = dates
        }

        /// A branch whose reflog has only its creation never got a commit of its own.
        func neverCommitted(_ branch: String) -> Bool {
            guard let d = FileManager.default.contents(atPath: commonDir + "/logs/refs/heads/" + branch) else { return false }
            return d.split(separator: UInt8(ascii: "\n")).count <= 1
        }
    }

    static func worktree(_ path: String, branch: String?, _ ri: RepoInfo) -> Worktree {
        // last activity: the newest of its branch's last commit and its own index, HEAD and reflog
        var times: [Date] = branch.flatMap { ri.commitDates[$0] }.map { [$0] } ?? []
        if let gd = gitdirOf(path) {
            for f in ["index", "HEAD", "logs/HEAD"] {
                if let t = (try? FileManager.default.attributesOfItem(atPath: gd + "/" + f))?[.modificationDate] as? Date {
                    times.append(t)
                }
            }
        }
        let merged = branch.map { ri.merged.contains($0) } ?? false
        return Worktree(path: path, repo: (ri.commonDir as NSString).deletingLastPathComponent, branch: branch,
                        merged: merged, noCommits: merged && branch.map(ri.neverCommitted) == true,
                        lastActivity: times.max() ?? .distantPast, outputs: ignoredOrLoose(outputCandidates(path), in: path))
    }

    /// The git dir of a worktree, from its .git file ("gitdir: /repo/.git/worktrees/name").
    static func gitdirOf(_ path: String) -> String? {
        guard let d = FileManager.default.contents(atPath: path + "/.git") else { return nil }
        let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("gitdir: ") else { return nil }
        return String(s.dropFirst(8))
    }

    static func branchIn(_ gitdir: String) -> String? {
        guard let d = FileManager.default.contents(atPath: gitdir + "/HEAD") else { return nil }
        let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasPrefix("ref: refs/heads/") ? String(s.dropFirst(16)) : nil
    }

    static func git(_ dir: String, _ args: [String]) -> Shell.Result? {
        Shell.run(gitPath, ["--no-optional-locks", "-C", dir] + args)
    }

    /// /usr/bin/git is a shim that looks up the developer tools on every call (~80 ms); find the
    /// real binary once.
    static let gitPath: String = {
        if let r = Shell.run("/usr/bin/xcrun", ["--find", "git"]), r.status == 0, !r.text.isEmpty { return r.text }
        return ["/opt/homebrew/bin/git", "/usr/local/bin/git"].first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/usr/bin/git"
    }()

    // MARK: output folders

    /// Output-named folders up to three levels down (packages/x/.dart_tool, ios/Pods), not looking
    /// inside one once found, nor into hidden folders.
    static func outputCandidates(_ root: String) -> [String] {
        var found: [String] = []
        func walk(_ dir: String, _ depth: Int) {
            for child in subfolders(dir) {
                let name = (child as NSString).lastPathComponent
                if outputNames.contains(name) {
                    if name != "Pods" || ["ios", "macos"].contains((dir as NSString).lastPathComponent) { found.append(child) }
                    continue
                }
                if !name.hasPrefix("."), depth < 2 { walk(child, depth + 1) }
            }
        }
        walk(root, 0)
        return found
    }

    /// Keeps the folders git ignores (a checked-in vendor/ or dist/ is source, not output).
    /// Outside any repo there's nothing to check against, so they're kept as they are.
    static func ignoredOrLoose(_ paths: [String], in dir: String) -> [String] {
        guard !paths.isEmpty else { return [] }
        guard let r = git(dir, ["check-ignore", "--"] + paths) else { return [] }
        if r.status == 128 { return paths }  // not a git repository
        let ignored = Set(r.text.split(separator: "\n").map { line -> String in
            let p = String(line)
            return p.hasPrefix("/") ? p : dir + "/" + p
        })
        return paths.filter { ignored.contains($0) }
    }

    /// Real (not symlinked) subfolders, sorted.
    static func subfolders(_ dir: String) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: dir), includingPropertiesForKeys: keys) else { return [] }
        return urls.compactMap { u -> String? in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isDirectory == true, v.isSymbolicLink != true
            else { return nil }
            return dir + "/" + u.lastPathComponent
        }.sorted()
    }
}

// MARK: - Cached scan

/// Scanning runs git a few times per worktree, so it's done every few minutes, not every refresh.
final class WorktreeStore: @unchecked Sendable {
    static let shared = WorktreeStore()
    private let lock = NSLock()
    private var cached: [WorktreeUnit] = []
    private var scannedAt: Date?
    private var scannedFor: Data?
    static let interval: TimeInterval = 5 * 60

    func units(_ cfg: Config.Worktrees, agentFolders: [String]) -> [WorktreeUnit] {
        let key = try? JSONEncoder().encode(Key(cfg))
        lock.lock()
        let due = scannedAt.map { Date().timeIntervalSince($0) > Self.interval } ?? true || key != scannedFor
        lock.unlock()
        if due { rescan(cfg) }
        lock.lock(); defer { lock.unlock() }
        return cached.map { u in
            var u = u
            u.agentOpen = agentFolders.contains { $0 == u.path || $0.hasPrefix(u.path + "/") }
            return u
        }
    }

    func rescan(_ cfg: Config.Worktrees) {
        let fresh = cfg.repos.isEmpty && cfg.roots.isEmpty ? [] : WorktreeScan.units(cfg)
        lock.lock(); defer { lock.unlock() }
        cached = fresh
        scannedAt = Date()
        scannedFor = try? JSONEncoder().encode(Key(cfg))
    }

    /// After a clean or remove, so the panel doesn't wait five minutes to show it.
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        scannedAt = nil
    }

    private struct Key: Encodable {
        let repos: [String], roots: [String], remove: String
        init(_ c: Config.Worktrees) {
            repos = c.repos.map { [$0.path, $0.removeCommand ?? "", $0.base ?? "", $0.title ?? ""].joined(separator: "|") }
            roots = c.roots.map { [$0.path, $0.removeCommand ?? "", $0.base ?? "", $0.title ?? ""].joined(separator: "|") }
            remove = c.removeCommand
        }
    }
}

// MARK: - Output sizes

/// du on every worktree's output every half hour would be minutes of disk churn, so each folder is
/// re-measured only when its worktree was touched since (at most every half hour), or once a day.
final class WorktreeSizes: @unchecked Sendable {
    static let shared = WorktreeSizes()
    private struct Entry: Codable { let kb: Int64; let at: Date }
    private let lock = NSLock()
    private var sizes: [String: Entry] = [:]
    private(set) var measuring = false
    private let file = Paths.support + "/worktree-sizes.json"

    init() {
        if let d = FileManager.default.contents(atPath: file), let s = try? JSONDecoder().decode([String: Entry].self, from: d) {
            sizes = s
        }
    }

    func kb(_ path: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return sizes[path]?.kb
    }

    /// nil until at least one of the folders has been measured.
    func total(_ paths: [String]) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        let known = paths.compactMap { sizes[$0]?.kb }
        return known.isEmpty && !paths.isEmpty ? nil : known.reduce(0, +)
    }

    func due(_ units: [WorktreeUnit]) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !measuring else { return [] }
        let now = Date()
        return units.flatMap { u in
            u.outputs.filter { p in
                guard let e = sizes[p] else { return true }
                let age = now.timeIntervalSince(e.at)
                return (u.lastActivity > e.at && age > 1800) || age > 86400
            }
        }
    }

    /// Runs du on each path. Call off the main thread. Folders no longer listed are forgotten.
    func measure(_ paths: [String], keeping listed: Set<String>) {
        lock.lock()
        if measuring { lock.unlock(); return }
        measuring = true
        lock.unlock()
        lock.lock()
        sizes = sizes.filter { listed.contains($0.key) }
        lock.unlock()
        // saved as it goes: the first pass over many worktrees takes minutes
        for (i, p) in paths.enumerated() where FileManager.default.fileExists(atPath: p) {
            guard let kb = SizeStore.du(p) else { continue }
            lock.lock()
            sizes[p] = Entry(kb: kb, at: Date())
            lock.unlock()
            if i % 10 == 9 { save() }
        }
        lock.lock()
        measuring = false
        lock.unlock()
        save()
    }

    private func save() {
        lock.lock()
        let snapshot = sizes
        lock.unlock()
        if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: URL(fileURLWithPath: file), options: .atomic) }
    }

    func forget(_ paths: [String]) {
        lock.lock(); defer { lock.unlock() }
        for p in paths { sizes[p] = nil }
    }
}

// MARK: - Actions

enum WorktreeActions {
    /// Uncommitted changes, an agent session in it: what to say before removing.
    static func removalWarnings(_ u: WorktreeUnit) -> [String] {
        var out: [String] = []
        if u.agentOpen { out.append("A Claude Code session is working in this folder.") }
        for m in u.members {
            let who = u.members.count > 1 ? (m.path as NSString).lastPathComponent + ": " : ""
            let n = WorktreeScan.git(m.path, ["status", "--porcelain"])?.text.split(separator: "\n").count ?? 0
            if n > 0 {
                out.append("\(who)\(n) uncommitted change\(n == 1 ? "" : "s"), which removing may discard.")
            }
            if m.noCommits, let b = m.branch {
                out.append("\(who)branch \(b) has no commits of its own.")
            } else if !m.merged, let b = m.branch {
                out.append("\(who)branch \(b) isn't merged into the default branch.")
            }
        }
        return out
    }

    /// Deletes the units' regenerable folders, re-checking each is still one, and measures what
    /// that freed with df (du overstates copy-on-write clones). Each unit is logged on its own.
    static func cleanOutput(_ units: [WorktreeUnit]) -> String? {
        ActionLog.$batch.withValue(ActionLog.batch ?? (units.count > 1 ? "clean merged worktrees" : nil)) { clean(units) }
    }

    private static func clean(_ units: [WorktreeUnit]) -> String? {
        let fm = FileManager.default
        let start = Engine.disk().0
        var counted: Int64 = 0, cleaned = 0
        for u in units {
            let before = Engine.disk().0
            let kb = u.outputKB ?? 0
            var deleted: [String] = []
            var targets: [(String, String)] = []
            for m in u.members { targets += WorktreeScan.ignoredOrLoose(m.outputs, in: m.path).map { ($0, m.path) } }
            targets += WorktreeScan.ignoredOrLoose(u.ownOutputs, in: u.path).map { ($0, u.path) }
            for (p, root) in targets where safeToDelete(p, under: root) {
                if (try? fm.removeItem(atPath: p)) != nil { deleted.append(p) }
            }
            guard !deleted.isEmpty else { continue }
            cleaned += 1
            counted += kb
            WorktreeSizes.shared.forget(deleted)
            ActionLog.record("clean worktree build output", title: "\(u.group)/\(u.name)",
                              target: ["path": u.path, "deleted": deleted.joined(separator: ","), "duKB": String(kb)],
                              result: nil, diskFreed: max(0, Engine.disk().0 - before))
        }
        WorktreeStore.shared.invalidate()
        let what = units.count == 1 ? units[0].name : "\(cleaned) worktree\(cleaned == 1 ? "" : "s")"
        guard cleaned > 0 else { return "Nothing to clean in \(units.count == 1 ? units[0].name : "those worktrees")" }
        let freed = max(0, Engine.disk().0 - start)
        var msg = "Cleaned \(what), freed \(human(bytes: freed))"
        if counted * 1024 > freed * 2, counted * 1024 - freed > 100 << 20 {
            msg += " (\(human(kb: counted)) counted; the rest was shared clones)"
        }
        return msg
    }

    private static func safeToDelete(_ p: String, under root: String) -> Bool {
        guard p.hasPrefix(root + "/"), WorktreeScan.outputNames.contains((p as NSString).lastPathComponent),
              let t = (try? FileManager.default.attributesOfItem(atPath: p))?[.type] as? FileAttributeType
        else { return false }
        return t == .typeDirectory
    }

    /// Runs the configured remove command, e.g. `git -C {repo} worktree remove {path}`.
    static func remove(_ u: WorktreeUnit) -> String? {
        let template = u.removeCommand
        if template.contains("{repo}") && u.repo == nil {
            return "removeCommand for \(u.group) uses {repo}, but a root folder has no single repo"
        }
        let cmd = template
            .replacingOccurrences(of: "{repo}", with: quote(u.repo ?? ""))
            .replacingOccurrences(of: "{path}", with: quote(u.path))
            .replacingOccurrences(of: "{name}", with: quote(u.name))
        let before = Engine.disk().0
        guard let r = Shell.run("/bin/sh", ["-c", cmd]) else { return "Couldn't run \(cmd)" }
        WorktreeSizes.shared.forget(u.outputs)
        WorktreeStore.shared.invalidate()
        let why = r.status == 0 ? nil
            : (r.errText.isEmpty ? r.text : r.errText).split(separator: "\n").first.map(String.init) ?? "exit \(r.status)"
        let freed = max(0, Engine.disk().0 - before)
        ActionLog.record("remove worktree", title: "\(u.group)/\(u.name)",
                          target: ["path": u.path, "command": cmd, "branches": u.branches.joined(separator: ",")],
                          result: why, diskFreed: why == nil ? freed : nil)
        if let why { return "Couldn't remove \(u.name): \(why)" }
        return "Removed \(u.name), freed \(human(bytes: freed))"
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

extension WorktreeUnit {
    /// "6d ago", "3h ago", "just now".
    var activityText: String {
        let s = Date().timeIntervalSince(lastActivity)
        if lastActivity == .distantPast { return "never used" }
        if s >= 86400 { return "\(Int(s / 86400))d ago" }
        if s >= 3600 { return "\(Int(s / 3600))h ago" }
        if s >= 120 { return "\(Int(s / 60))m ago" }
        return "just now"
    }

    var tags: [String] {
        var t: [String] = []
        if merged { t.append("merged") } else if noCommits { t.append("no commits") }
        if members.count > 1 { t.append("\(members.count) repos") }
        if members.contains(where: { $0.branch == nil }) && members.count == 1 { t.append("detached") }
        if agentOpen { t.append("Claude open") }
        return t
    }

    /// Worth cleaning without asking much: merged, untouched for a while, nobody working in it.
    func isChore(idleDays limit: Int) -> Bool {
        merged && !agentOpen && idleDays >= limit && (outputKB ?? 0) >= 50 * 1024
    }
}

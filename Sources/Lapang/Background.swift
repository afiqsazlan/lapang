import Darwin
import Foundation

// Background jobs gone wrong: a LaunchAgent that keeps crashing and being started again (a brew
// service with a bad config restarts every few seconds), and the log files such a loop fills.

struct CrashLoop: Identifiable {
    let label: String
    let plist: String
    let lastExit: Int
    let runs: Int
    /// Starts per hour since Lapang last looked; nil the first time.
    let runsPerHour: Double?
    let program: String?
    let logs: [String]
    var id: String { label }

    /// "php@8.3" for "homebrew.mxcl.php@8.3".
    var brewService: String? { label.hasPrefix("homebrew.mxcl.") ? String(label.dropFirst(14)) : nil }

    var fixCommand: String {
        brewService.map { "brew services stop \($0)" } ?? "launchctl bootout gui/\(getuid())/\(label)"
    }

    var subtitle: String {
        var parts = ["exit \(lastExit)"]
        if let r = runsPerHour, r >= 1 { parts.append("restarting \(Int(r.rounded()))×/h") } else { parts.append("\(runs) starts") }
        return parts.joined(separator: " · ")
    }
}

struct RunawayLog: Identifiable {
    let path: String
    let bytes: Int64
    let mbPerDay: Double
    /// From the file's size and age, because Lapang hasn't watched it for an hour yet.
    let estimated: Bool
    /// The LaunchAgent that writes it, when one names it.
    let agent: String?
    var id: String { path }
}

enum LaunchAgents {
    static var agentsDir: String { Paths.home + "/Library/LaunchAgents" }

    /// `launchctl print gui/<uid>`'s service list: label → (pid, last exit status).
    static func services() -> [String: (pid: pid_t, exit: Int?)] {
        guard let r = Shell.run("/bin/launchctl", ["print", "gui/\(getuid())"]), r.status == 0 else { return [:] }
        var out: [String: (pid_t, Int?)] = [:]
        var inside = false
        for line in r.text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "services = {" { inside = true; continue }
            if inside && t == "}" { break }
            guard inside else { continue }
            let cols = t.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 3, let pid = pid_t(cols[0]) else { continue }
            out[String(cols[2])] = (pid, Int(cols[1]))
        }
        return out
    }

    /// Pids launchd started on purpose: their parent is pid 1 because launchd runs them, not because
    /// something died.
    static func jobPIDs(_ services: [String: (pid: pid_t, exit: Int?)]) -> Set<pid_t> {
        Set(services.values.map(\.pid).filter { $0 > 0 })
    }

    /// Your LaunchAgents' plists, by label.
    static func plists() -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: agentsDir)) ?? [] where name.hasSuffix(".plist") {
            let path = agentsDir + "/" + name
            guard let d = FileManager.default.contents(atPath: path),
                  var plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
                  let label = plist["Label"] as? String else { continue }
            plist["_path"] = path
            out[label] = plist
        }
        return out
    }

    /// Agents of yours whose last run failed and that keep being started again. `runs` comes from
    /// `launchctl print gui/<uid>/<label>`, asked only of the failing ones.
    static func crashLoops(_ services: [String: (pid: pid_t, exit: Int?)], plists: [String: [String: Any]],
                           ignore: [String]) -> [CrashLoop] {
        var seen = RunStore.load()
        var out: [CrashLoop] = []
        let now = Date()
        for (label, svc) in services {
            guard let exit = svc.exit, exit != 0, let plist = plists[label], !ignore.contains(label),
                  let r = Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]) else { continue }
            let runs = Int(field(r.text, "runs") ?? "") ?? 0
            // the baseline moves on once it's an hour old, so the rate covers the last hour or two
            var base = seen[label]
            if base == nil || base!.runs > runs || now.timeIntervalSince(base!.t) > 2 * 3600 {
                base = .init(runs: runs, t: now)
            }
            var rate: Double?
            if let b = base, now.timeIntervalSince(b.t) >= 30 {
                rate = Double(runs - b.runs) / (now.timeIntervalSince(b.t) / 3600)
            }
            seen[label] = base!.runs < runs && now.timeIntervalSince(base!.t) > 3600 ? .init(runs: runs, t: now) : base
            // respawning: started again at least twice lately, or many starts with a failing last run
            // (the first look: many starts and not running now, so it's between crashes)
            let looping = rate != nil ? runs - base!.runs >= 2 : runs >= 10 && svc.pid == 0
            guard looping else { continue }
            let logs = ["StandardErrorPath", "StandardOutPath"].compactMap { plist[$0] as? String }.map(Paths.expand)
            let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
            out.append(CrashLoop(label: label, plist: plist["_path"] as? String ?? "", lastExit: exit, runs: runs,
                                 runsPerHour: rate, program: program, logs: Array(Set(logs)).sorted()))
        }
        seen = seen.filter { now.timeIntervalSince($0.value.t) < 7 * 86400 }
        RunStore.save(seen)
        return out.sorted { $0.runs > $1.runs }
    }

    static func field(_ text: String, _ name: String) -> String? {
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(name + " = ") { return String(t.dropFirst(name.count + 3)) }
        }
        return nil
    }

    private enum RunStore {
        struct Seen: Codable { let runs: Int; let t: Date }
        static let file = Paths.support + "/launch-agents.json"
        static func load() -> [String: Seen] {
            FileManager.default.contents(atPath: file).flatMap { try? JSONDecoder().decode([String: Seen].self, from: $0) } ?? [:]
        }
        static func save(_ s: [String: Seen]) {
            if let d = try? JSONEncoder().encode(s) { try? d.write(to: URL(fileURLWithPath: file), options: .atomic) }
        }
    }
}

enum RunawayLogs {
    private struct Sample: Codable { let t: Date; let bytes: Int64 }
    private static let file = Paths.support + "/log-sizes.json"

    /// Homebrew's and your own log folders, plus the logs your LaunchAgents write to.
    static func dirs(_ config: Config) -> [String] {
        (config.logs.dirs.isEmpty ? ["/opt/homebrew/var/log", "/usr/local/var/log", "~/Library/Logs"] : config.logs.dirs)
            .map(Paths.expand)
    }

    /// Files growing faster than the configured MB a day. Sizes are kept for two days to measure that;
    /// until a file has been watched for an hour, its average since it was created stands in.
    static func find(_ config: Config, agentLogs: [String: String]) -> [RunawayLog] {
        let fm = FileManager.default
        var files = Set(agentLogs.keys)
        for dir in dirs(config) {
            guard let e = fm.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.isRegularFileKey],
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                if e.level > 2 { e.skipDescendants(); continue }
                files.insert(url.path)
            }
        }
        var store: [String: [Sample]] = (fm.contents(atPath: file).flatMap { try? JSONDecoder().decode([String: [Sample]].self, from: $0) }) ?? [:]
        let now = Date()
        var out: [RunawayLog] = []
        let limit = config.logs.growthMBPerDay
        for path in files {
            guard let a = try? fm.attributesOfItem(atPath: path), a[.type] as? FileAttributeType == .typeRegular,
                  let size = (a[.size] as? NSNumber)?.int64Value else { continue }
            var samples = (store[path] ?? []).filter { now.timeIntervalSince($0.t) < 2 * 86400 }
            // a shrink means it was truncated or rotated: start over
            if let last = samples.last, size < last.bytes { samples = [] }
            let base = samples.first { now.timeIntervalSince($0.t) >= 3600 }
            if samples.last.map({ now.timeIntervalSince($0.t) >= 600 }) ?? true { samples.append(Sample(t: now, bytes: size)) }
            if size >= 1 << 20 { store[path] = samples } else { store[path] = nil }
            var rate: Double, estimated = false
            if let base {
                rate = Double(size - base.bytes) / 1_048_576 / (now.timeIntervalSince(base.t) / 86400)
            } else if let created = a[.creationDate] as? Date, now.timeIntervalSince(created) >= 3600 {
                rate = Double(size) / 1_048_576 / (now.timeIntervalSince(created) / 86400)
                estimated = true
            } else {
                continue
            }
            guard rate >= limit, size >= 50 << 20 else { continue }
            out.append(RunawayLog(path: path, bytes: size, mbPerDay: rate, estimated: estimated, agent: agentLogs[path]))
        }
        store = store.filter { files.contains($0.key) }
        if let d = try? JSONEncoder().encode(store) { try? d.write(to: URL(fileURLWithPath: file), options: .atomic) }
        return out.sorted { $0.mbPerDay > $1.mbPerDay }
    }
}

enum BackgroundActions {
    /// `brew services stop <name>` for a Homebrew service; otherwise `launchctl bootout`, which stops
    /// the agent until you log in again (its plist stays where it is).
    static func stop(_ loop: CrashLoop) -> String? {
        let r: Shell.Result?
        if let name = loop.brewService {
            guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            else { return "Homebrew isn't installed where Lapang looks" }
            r = Shell.run(brew, ["services", "stop", name])
        } else {
            r = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(loop.label)"])
        }
        let error = r?.status == 0 ? nil : (r?.errText.split(separator: "\n").last.map(String.init) ?? "couldn't run it")
        ActionLog.record("stop crash-looping agent", title: loop.label,
                         target: ["label": loop.label, "plist": loop.plist, "command": loop.fixCommand,
                                  "lastExit": "\(loop.lastExit)", "runs": "\(loop.runs)"],
                         result: error)
        let name = loop.brewService ?? loop.label
        return error.map { "Couldn't stop \(name): \($0)" } ?? "Stopped \(name)"
    }

    /// Empties a log in place, so whatever writes to it carries on writing to the same file.
    static func truncate(_ log: RunawayLog, allowed: [String]) -> String? {
        let target = ["path": log.path, "bytes": "\(log.bytes)", "mbPerDay": "\(Int(log.mbPerDay))"]
        let inside = allowed.contains { log.path.hasPrefix($0 + "/") } || log.agent != nil
        let link = (try? FileManager.default.destinationOfSymbolicLink(atPath: log.path)) != nil
        guard inside, !link else {
            ActionLog.record("truncate log", title: Paths.abbreviate(log.path), target: target, result: "skipped: not a log Lapang watches")
            return "Skipped \(Paths.abbreviate(log.path))"
        }
        let before = Engine.disk().0
        let ok = Darwin.truncate(log.path, 0) == 0
        let error = ok ? nil : String(cString: strerror(errno))
        ActionLog.record("truncate log", title: Paths.abbreviate(log.path), target: target, result: error,
                         diskFreed: ok ? max(0, Engine.disk().0 - before) : nil)
        return error.map { "Couldn't empty \((log.path as NSString).lastPathComponent): \($0)" }
            ?? "Emptied \((log.path as NSString).lastPathComponent), freed \(human(bytes: log.bytes))"
    }
}

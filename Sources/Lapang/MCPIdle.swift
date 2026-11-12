import Darwin
import Foundation

// Idle MCP servers. Every agent session starts its own MCP server (the Dart one brings a language
// server along, 2-3 GB together), and they outlive their usefulness. An MCP server only uses CPU
// when its session calls a tool, so a server whose CPU time hasn't grown for hours is idle. Its
// language server isn't a signal: it re-analyses files whenever they change, used or not.

enum MCPActivity {
    private struct Entry: Codable {
        let started: Date
        var cpuNs: UInt64
        var activeAt: Date
    }

    /// CPU growth below this between samples is housekeeping, not a tool call.
    static let threshold: UInt64 = 30_000_000  // 30 ms

    private static let file = Paths.support + "/mcp-activity.json"
    private static let lock = NSLock()

    /// Records each server's CPU time and returns when each was last seen doing work, by pid.
    /// A server seen for the first time counts as active now: there's no telling what it did before.
    static func update(_ servers: [(pid: pid_t, started: Date, cpuNs: UInt64)]) -> [pid_t: Date] {
        lock.lock(); defer { lock.unlock() }
        var stored: [String: Entry] = [:]
        if let d = FileManager.default.contents(atPath: file) {
            stored = (try? JSONDecoder().decode([String: Entry].self, from: d)) ?? [:]
        }
        let now = Date()
        var fresh: [String: Entry] = [:]
        var out: [pid_t: Date] = [:]
        for s in servers {
            let key = String(s.pid)
            var e = stored[key]
            // a different process that reused the pid starts over
            if let old = e, abs(old.started.timeIntervalSince(s.started)) > 1 { e = nil }
            if var old = e {
                if s.cpuNs > old.cpuNs + threshold || s.cpuNs < old.cpuNs {
                    old.cpuNs = s.cpuNs
                    old.activeAt = now
                }
                e = old
            } else {
                e = Entry(started: s.started, cpuNs: s.cpuNs, activeAt: now)
            }
            fresh[key] = e
            out[s.pid] = e!.activeAt
        }
        if let d = try? JSONEncoder().encode(fresh) {
            try? d.write(to: URL(fileURLWithPath: file), options: .atomic)
        }
        return out
    }

    /// User plus system CPU time in nanoseconds (libproc reports mach ticks on Apple silicon).
    static func cpuNs(_ task: proc_taskinfo) -> UInt64 {
        (task.pti_total_user + task.pti_total_system) * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()
}

/// The rule in config.json: stop idle MCP servers beyond the newest few.
enum MCPCleanup {
    struct Candidate {
        let server: DevProc
        let children: [DevProc]
        var bytes: UInt64 { server.rssBytes + children.reduce(0) { $0 + $1.rssBytes } }
    }

    /// Idle servers, oldest first, never one of the `keepNewest` most recently started.
    static func candidates(_ procs: [DevProc], idleHours: Double, keepNewest: Int) -> [Candidate] {
        let servers = procs.filter { $0.kind == "mcp" }.sorted { $0.started > $1.started }
        return servers.dropFirst(max(0, keepNewest))
            .filter { ($0.idleHours ?? 0) >= idleHours }
            .sorted { $0.started < $1.started }
            .map { s in Candidate(server: s, children: procs.filter { $0.ppid == s.pid }) }
    }

    /// Stops each candidate with its language server (each process logged); returns the ones that stopped.
    static func stop(_ list: [Candidate], auto: Bool) -> [Candidate] {
        let action = auto ? "auto-stop idle MCP server" : "stop idle MCP server"
        return ActionLog.$batch.withValue(list.count > 1 ? action + "s" : nil) {
            list.filter { Actions.kill($0.server, children: $0.children, action: action) == nil }
        }
    }

    static func summary(_ stopped: [Candidate]) -> String {
        let freed = stopped.reduce(UInt64(0)) { $0 + $1.bytes }
        let n = stopped.count
        return "Stopped \(n) idle MCP server\(n == 1 ? "" : "s"), freed \(human(bytes: Int64(freed)))"
    }
}

extension DevProc {
    /// Hours since an MCP server last used CPU; nil for other processes.
    var idleHours: Double? { idleSince.map { Date().timeIntervalSince($0) / 3600 } }

    /// "idle 3h", shown once a server has been quiet for an hour.
    var idleTag: String? {
        guard let h = idleHours, h >= 1 else { return nil }
        return h >= 48 ? "idle \(Int(h / 24))d" : "idle \(Int(h))h"
    }
}

/// "2h", "1.5h": the rule's idle threshold as written in config.json.
func hoursLabel(_ h: Double) -> String {
    h == h.rounded() ? "\(Int(h))h" : String(format: "%.1fh", h)
}

import Darwin
import Foundation

// The process tree, read once per refresh: MCP servers counted by command with everything they
// started, and helper servers (language servers and the like) left running after their parent died.

struct ProcEntry {
    let pid: pid_t
    let ppid: pid_t
    let path: String
    /// Memory footprint; nil for other users' processes, which libproc won't read.
    let footprint: UInt64?
}

enum ProcTable {
    static func build() -> [pid_t: ProcEntry] {
        var out: [pid_t: ProcEntry] = [:]
        for pid in Engine.allPIDs() {
            guard let path = Engine.execPath(pid), let ppid = Engine.parentPID(pid) else { continue }
            out[pid] = ProcEntry(pid: pid, ppid: ppid, path: path, footprint: MemoryProbe.footprint(pid))
        }
        return out
    }

    static func children(_ table: [pid_t: ProcEntry]) -> [pid_t: [pid_t]] {
        var kids: [pid_t: [pid_t]] = [:]
        for e in table.values where e.ppid > 0 { kids[e.ppid, default: []].append(e.pid) }
        return kids
    }

    /// The process and everything under it.
    static func descendants(of pid: pid_t, _ kids: [pid_t: [pid_t]]) -> [pid_t] {
        var out = [pid], i = 0
        while i < out.count {
            out += kids[out[i]] ?? []
            i += 1
            if out.count > 2000 { break }
        }
        return out
    }
}

/// Copies of one MCP server command, e.g. 6 × "dart mcp-server" with their language servers.
struct MCPGroup: Identifiable {
    let command: String
    var pids: [pid_t]
    /// The servers plus every process they started.
    var bytes: UInt64
    var processes: Int
    /// Copies whose session is gone (their parent is launchd now).
    var orphaned: Int
    var id: String { command }

    /// "6× dart mcp-server · 10.5 GB"
    var summary: String { "\(pids.count)× \(command) · \(human(bytes: Int64(bytes)))" }
}

enum MCPFanout {
    /// Every MCP server of yours, grouped by command. A wrapper and the server it starts (npx and node)
    /// count once, as the outermost one.
    static func groups(_ table: [pid_t: ProcEntry], launchdJobs: Set<pid_t>) -> (groups: [MCPGroup], servers: Set<pid_t>) {
        var labels: [pid_t: String] = [:]
        for e in table.values where e.footprint != nil && !Engine.isClaudeCode(e.path) {
            if let label = label(e.path, Engine.args(e.pid)) { labels[e.pid] = label }
        }
        let kids = ProcTable.children(table)
        var groups: [String: MCPGroup] = [:]
        for (pid, label) in labels {
            var p = table[pid]?.ppid ?? 0, nested = false
            for _ in 0 ..< 8 where p > 1 {
                if labels[p] != nil { nested = true; break }
                p = table[p]?.ppid ?? 0
            }
            guard !nested else { continue }
            let tree = ProcTable.descendants(of: pid, kids)
            let bytes = tree.reduce(UInt64(0)) { $0 + (table[$1]?.footprint ?? 0) }
            var g = groups[label] ?? MCPGroup(command: label, pids: [], bytes: 0, processes: 0, orphaned: 0)
            g.pids.append(pid)
            g.bytes += bytes
            g.processes += tree.count
            if table[pid]?.ppid == 1 && !launchdJobs.contains(pid) { g.orphaned += 1 }
            groups[label] = g
        }
        let list = groups.values.map { g -> MCPGroup in var g = g; g.pids.sort(); return g }.sorted { $0.bytes > $1.bytes }
        return (list, Set(labels.keys))
    }

    /// "dart mcp-server", "node @playwright/mcp", "github-mcp-server"; nil when it isn't an MCP server.
    static func label(_ path: String, _ args: [String]) -> String? {
        let exe = (path as NSString).lastPathComponent
        if let t = KnownCommands.mcpToken(exe) { return t }
        for a in args.dropFirst() {
            if let t = KnownCommands.mcpToken(a) { return "\(exe) \(t)" }
        }
        return nil
    }
}

enum Orphans {
    /// Helper servers whose parent is gone: reparented to launchd (pid 1) without being a launchd job,
    /// or still under an MCP server that has itself lost its session. Watched processes already in
    /// `procs` are marked; others are added, so cleaning and kill-old-mcp see them too.
    static func mark(_ procs: inout [DevProc], table: [pid_t: ProcEntry], mcpServers: Set<pid_t>,
                     launchdJobs: Set<pid_t>, extra: [String]) {
        let parentGone = { (e: ProcEntry) -> Bool in
            if e.ppid == 1 { return !launchdJobs.contains(e.pid) }
            guard mcpServers.contains(e.ppid), let parent = table[e.ppid] else { return false }
            return parent.ppid == 1 && !launchdJobs.contains(parent.pid)
        }
        for e in table.values where e.footprint != nil && !Engine.isClaudeCode(e.path) {
            let args = Engine.args(e.pid)
            guard let role = KnownCommands.childServer(e.path, args, extra: extra), parentGone(e) else { continue }
            if let i = procs.firstIndex(where: { $0.pid == e.pid }) {
                procs[i].orphaned = true
                procs[i].stale = true
                continue
            }
            var bsd = proc_bsdinfo()
            let started = proc_pidinfo(e.pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0
                ? Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)) : Date()
            var p = DevProc(pid: e.pid, ppid: e.ppid, name: (e.path as NSString).lastPathComponent,
                            kind: role.contains("mcp") ? "mcp" : "lsp", footprintBytes: e.footprint ?? 0,
                            started: started, cwd: Engine.currentDir(e.pid) ?? "", stale: true)
            p.orphaned = true
            procs.append(p)
        }
        procs.sort { $0.pid < $1.pid }
    }
}

import Darwin
import Foundation
import IOKit

// Paging: how hard the Mac is reading memory back from the disk, sampled over a short window.
// Pressure alone misses the worst case: once swap is full, macOS reports "normal" pressure while
// every app waits on the disk. Swap nearly full plus heavy paging is swap thrashing.

/// Cumulative counters at one moment: the system's page-ins and swap traffic, and disk operations.
struct PagingCounters {
    let t: Date
    let pageins: UInt64
    let swapins: UInt64
    let swapouts: UInt64
    let readOps: UInt64
    let writeOps: UInt64
    let readBytes: UInt64
    let writeBytes: UInt64

    static func now() -> PagingCounters {
        var v = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &v) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let ok = kr == KERN_SUCCESS
        let d = disk()
        return PagingCounters(t: Date(), pageins: ok ? v.pageins : 0, swapins: ok ? v.swapins : 0,
                              swapouts: ok ? v.swapouts : 0, readOps: d.readOps, writeOps: d.writeOps,
                              readBytes: d.readBytes, writeBytes: d.writeBytes)
    }

    /// Every block storage driver's statistics, summed (the internal SSD plus anything attached).
    private static func disk() -> (readOps: UInt64, writeOps: UInt64, readBytes: UInt64, writeBytes: UInt64) {
        var out: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS
        else { return out }
        defer { IOObjectRelease(it) }
        while case let e = IOIteratorNext(it), e != 0 {
            defer { IOObjectRelease(e) }
            guard let st = IORegistryEntryCreateCFProperty(e, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            let n = { (k: String) in (st[k] as? NSNumber)?.uint64Value ?? 0 }
            out.0 += n("Operations (Read)")
            out.1 += n("Operations (Write)")
            out.2 += n("Bytes (Read)")
            out.3 += n("Bytes (Write)")
        }
        return out
    }
}

/// A process reading pages in from the disk during the window.
struct Pager: Codable {
    let pid: Int32
    let name: String
    /// Pages read in during the window.
    let pageins: UInt64
    let seconds: Double

    var bytesPerSecond: Double { Double(pageins) * Double(vm_kernel_page_size) / max(seconds, 0.1) }
    var isSpotlight: Bool { ["mds_stores", "mds", "mdworker", "mdworker_shared"].contains(name) }
}

struct Paging {
    var seconds: Double
    var pageinsPerSec: Double
    var swapinsPerSec: Double
    var swapoutsPerSec: Double
    var readOpsPerSec: Double
    var writeOpsPerSec: Double
    var readBytesPerSec: Double
    var writeBytesPerSec: Double
    /// Swap used over swap allocated; macOS adds swap files as it needs them, so this alone is common.
    var swapFullShare: Double
    var swapNearlyFull: Bool
    /// Paging or disk traffic over the configured limits.
    var heavy: Bool
    var topPagers: [Pager] = []

    var thrashing: Bool { swapNearlyFull && heavy }
    var iops: Double { readOpsPerSec + writeOpsPerSec }
    /// Pages coming back in from swap or from files, in bytes a second.
    var pagingBytesPerSec: Double { (pageinsPerSec + swapinsPerSec) * Double(vm_kernel_page_size) }
    var diskBytesPerSec: Double { readBytesPerSec + writeBytesPerSec }
    /// Spotlight's indexer is among the processes paging the most.
    var spotlightPaging: Bool { topPagers.prefix(3).contains(where: \.isSpotlight) }

    /// "Paging 210 MB/s · disk 11.2k IOPS"
    var summary: String {
        "paging \(human(rate: pagingBytesPerSec)) · disk \(iopsText(iops)) IOPS, \(human(rate: diskBytesPerSec))"
    }

    var pagersText: String {
        topPagers.prefix(3).map { "\($0.name) \(human(rate: $0.bytesPerSecond))" }.joined(separator: ", ")
    }

    static func measure(from a: PagingCounters, to b: PagingCounters, swapUsed: UInt64, swapTotal: UInt64,
                        rule: Config.Thrash) -> Paging {
        let secs = max(b.t.timeIntervalSince(a.t), 0.001)
        let rate = { (x: UInt64, y: UInt64) in y >= x ? Double(y - x) / secs : 0 }
        let share = swapTotal > 0 ? Double(swapUsed) / Double(swapTotal) : 0
        var p = Paging(seconds: secs, pageinsPerSec: rate(a.pageins, b.pageins), swapinsPerSec: rate(a.swapins, b.swapins),
                       swapoutsPerSec: rate(a.swapouts, b.swapouts),
                       readOpsPerSec: rate(a.readOps, b.readOps), writeOpsPerSec: rate(a.writeOps, b.writeOps),
                       readBytesPerSec: rate(a.readBytes, b.readBytes), writeBytesPerSec: rate(a.writeBytes, b.writeBytes),
                       swapFullShare: share,
                       swapNearlyFull: swapTotal >= 1 << 30 && share >= rule.swapFullShare,
                       heavy: false)
        p.heavy = p.pagingBytesPerSec >= rule.pagingMBps * 1_048_576 || p.iops >= rule.diskIOPS
        return p
    }

    /// Worth naming the processes: within half of a limit, or swap nearly full with any real paging.
    func worthNamingPagers(_ rule: Config.Thrash) -> Bool {
        heavy || pagingBytesPerSec >= rule.pagingMBps * 524_288 || iops >= rule.diskIOPS / 2
    }

    /// Page-ins per process over a `seconds` window, most first. Uses top, which can read root-owned
    /// processes such as Spotlight's mds_stores (libproc can't, for a normal user).
    static func pagers(seconds: Int = 1, limit: Int = 5) -> [Pager] {
        guard let r = Shell.run("/usr/bin/top", ["-l", "2", "-s", "\(seconds)", "-c", "d", "-o", "pageins",
                                                 "-n", "400", "-stats", "pid,pageins,command"]),
              r.status == 0 else { return [] }
        return parseTop(r.text, seconds: Double(seconds)).prefix(limit).map { $0 }
    }

    /// The second sample of `top -l 2 -c d -stats pid,pageins,command`: deltas over the window.
    static func parseTop(_ text: String, seconds: Double) -> [Pager] {
        let lines = text.components(separatedBy: "\n")
        guard let header = lines.lastIndex(where: { $0.hasPrefix("PID") && $0.contains("PAGEINS") }) else { return [] }
        var out: [Pager] = []
        for line in lines[(header + 1)...] {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]) else { continue }
            let n = topNumber(String(parts[1]))
            guard n > 0 else { continue }
            out.append(Pager(pid: pid, name: friendlyName(pid, String(parts[2]).trimmingCharacters(in: .whitespaces)),
                             pageins: n, seconds: seconds))
        }
        return out.sorted { $0.pageins > $1.pageins }
    }

    /// top writes "1234", "1234+", or "12K" / "3M" for big values.
    static func topNumber(_ s: String) -> UInt64 {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        let mult: UInt64 = t.hasSuffix("K") ? 1_000 : t.hasSuffix("M") ? 1_000_000 : t.hasSuffix("G") ? 1_000_000_000 : 1
        return (UInt64(t.trimmingCharacters(in: CharacterSet(charactersIn: "KMG"))) ?? 0) * mult
    }

    /// top cuts command names to 16 characters; the full path's name is better where it can be read,
    /// with a tool's role added for interpreters ("dart language-server", "node tsserver").
    private static func friendlyName(_ pid: pid_t, _ fallback: String) -> String {
        guard let path = Engine.execPath(pid) else { return fallback }
        let exe = (path as NSString).lastPathComponent
        if let r = path.range(of: ".app/") {
            return ((String(path[..<r.lowerBound]) as NSString).lastPathComponent as NSString).deletingPathExtension
                + (exe.contains("Helper") ? " (helper)" : "")
        }
        if let role = KnownCommands.role(Engine.args(pid)) { return "\(exe) \(role)" }
        return exe
    }
}

/// Command words that say what an interpreter (dart, node, python, java) is running.
enum KnownCommands {
    /// Programs that editors and MCP servers start as children: they should die with their parent.
    static let childServers = ["language-server", "languageserver", "lsp", "tsserver", "typescript-language-server",
                               "rust-analyzer", "gopls", "pyright", "pyright-langserver", "pylsp", "sourcekit-lsp",
                               "clangd", "intelephense", "jdtls", "analysis_server"]

    /// "language-server" for `dart language-server`, "tsserver" for `node …/tsserver.js`.
    static func role(_ args: [String], extra: [String] = []) -> String? {
        for a in args.dropFirst() where !a.hasPrefix("-") {
            let base = ((a as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
            if (childServers + extra).contains(where: { tokenMatch(base, $0) }) { return base }
            if mcpToken(a) != nil { return mcpToken(a) }
        }
        return nil
    }

    /// The child-server word an argument or executable name matches, if any.
    static func childServer(_ path: String, _ args: [String], extra: [String]) -> String? {
        let exe = (path as NSString).lastPathComponent.lowercased()
        let words = childServers + extra.map { $0.lowercased() }
        if words.contains(where: { tokenMatch(exe, $0) }) { return exe }
        for a in args.dropFirst() where !a.hasPrefix("-") {
            let base = ((a as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
            if words.contains(where: { tokenMatch(base, $0) }) { return base }
        }
        return nil
    }

    /// `word` appears in `s` as a whole token: "dart-language-server" matches "language-server",
    /// "lsp" matches "sourcekit-lsp" but not "helpspot".
    static func tokenMatch(_ s: String, _ word: String) -> Bool {
        var from = s.startIndex
        while let r = s.range(of: word, range: from ..< s.endIndex) {
            let before = r.lowerBound == s.startIndex || "-_./@ ".contains(s[s.index(before: r.lowerBound)])
            let after = r.upperBound == s.endIndex || "-_./@ ".contains(s[r.upperBound])
            if before && after { return true }
            from = s.index(after: r.lowerBound)
        }
        return false
    }

    /// The MCP server named by an argument: "mcp-server", "@playwright/mcp", "github-mcp-server".
    static func mcpToken(_ arg: String) -> String? {
        guard !arg.hasPrefix("-") else { return nil }
        var name = arg
        if name.hasPrefix("@"), let slash = name.firstIndex(of: "/") {
            // a scoped npm package, "@scope/name@1.2.3"
            let rest = name[name.index(after: slash)...]
            name = String(name[...slash]) + (rest.split(separator: "@").first.map(String.init) ?? "")
        } else {
            name = (name as NSString).lastPathComponent
            if let at = name.firstIndex(of: "@"), at != name.startIndex { name = String(name[..<at]) }
            for ext in [".js", ".mjs", ".cjs", ".py", ".ts"] where name.hasSuffix(ext) { name = String(name.dropLast(ext.count)) }
        }
        let lower = name.lowercased()
        guard tokenMatch(lower, "mcp") || lower.contains("modelcontextprotocol") else { return nil }
        return name
    }
}

func human(rate bytesPerSec: Double) -> String {
    human(bytes: Int64(bytesPerSec)) + "/s"
}

/// "850", "11.2k"
func iopsText(_ n: Double) -> String {
    n >= 10_000 ? String(format: "%.0fk", n / 1000) : n >= 1000 ? String(format: "%.1fk", n / 1000) : String(format: "%.0f", n)
}

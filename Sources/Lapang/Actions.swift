import Darwin
import Foundation

/// Built-in actions. Each returns a short message for the panel's status line.
enum Actions {
    static func shutdownSim(_ udid: String) -> String? {
        let r = Shell.run("/usr/bin/xcrun", ["simctl", "shutdown", udid])
        return r?.status == 0 ? nil : "Couldn't shut down the simulator"
    }

    static func shutdownAllSims() -> String? {
        let r = Shell.run("/usr/bin/xcrun", ["simctl", "shutdown", "all"])
        return r?.status == 0 ? "All simulators shut down" : "Couldn't shut down simulators"
    }

    /// Kills a watched process, re-checking it is still the same program first (pids get reused).
    static func kill(_ p: DevProc, children: [DevProc] = []) -> String? {
        var killed = 0
        for c in children where sameProcess(c) { if Darwin.kill(c.pid, SIGTERM) == 0 { killed += 1 } }
        if sameProcess(p), Darwin.kill(p.pid, SIGTERM) == 0 { killed += 1 }
        return killed > 0 ? nil : "Process \(p.pid) was already gone"
    }

    static func killAll(_ procs: [DevProc]) -> String? {
        let n = procs.filter { sameProcess($0) && Darwin.kill($0.pid, SIGTERM) == 0 }.count
        return "Killed \(n) process\(n == 1 ? "" : "es")"
    }

    private static func sameProcess(_ p: DevProc) -> Bool {
        guard let path = Engine.execPath(p.pid) else { return false }
        return (path as NSString).lastPathComponent == p.name
    }

    static func deleteDerived(_ entries: [DerivedEntry], root: String) -> String? {
        let before = Engine.disk().0
        var n = 0
        for e in entries {
            // only ever delete direct children of the DerivedData folder
            guard (e.path as NSString).deletingLastPathComponent == root else { continue }
            if (try? FileManager.default.removeItem(atPath: e.path)) != nil {
                SizeStore.shared.forget(e.path)
                n += 1
            }
        }
        let freed = max(0, Engine.disk().0 - before)
        return "Deleted \(n) build cache\(n == 1 ? "" : "s"), freed \(human(bytes: freed))"
    }

    /// Empties a cache folder, keeping the folder itself.
    static func clearCache(_ c: CacheInfo) -> String? {
        let fm = FileManager.default
        let before = Engine.disk().0
        guard c.clearable, let items = try? fm.contentsOfDirectory(atPath: c.path) else { return "Nothing to clear" }
        for i in items { try? fm.removeItem(atPath: c.path + "/" + i) }
        SizeStore.shared.forget(c.path)
        return "Cleared \(c.name), freed \(human(bytes: max(0, Engine.disk().0 - before)))"
    }
}

func human(kb: Int64?) -> String {
    guard let kb else { return "?" }
    return human(bytes: kb * 1024)
}

func human(bytes: Int64) -> String {
    let b = Double(bytes)
    if b >= 1_073_741_824 { return String(format: "%.1f GB", b / 1_073_741_824) }
    if b >= 1_048_576 { return String(format: "%.0f MB", b / 1_048_576) }
    if b >= 1024 { return String(format: "%.0f KB", b / 1024) }
    return "\(bytes) B"
}

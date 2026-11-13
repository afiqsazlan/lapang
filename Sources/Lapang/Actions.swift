import Darwin
import Foundation

/// Built-in actions. Each returns a short message for the panel's status line, and records
/// what it did in the action log, one entry per item acted on.
enum Actions {
    /// Checks again just before acting: a build may have started since the panel last refreshed.
    static func shutdownSim(_ sim: Sim, force: Bool = false) -> String? {
        if !force, building([sim]).contains(sim.udid) {
            log("shut down simulator", sim, "skipped: building")
            return "\(sim.name) is building, left running"
        }
        let r = Shell.run("/usr/bin/xcrun", ["simctl", "shutdown", sim.udid])
        let error = r?.status == 0 ? nil : "Couldn't shut down the simulator"
        log("shut down simulator", sim, simctlError(r))
        return error
    }

    /// `simctl shutdown all`, or one by one around any simulator that is building.
    static func shutdownAllSims(_ sims: [Sim]) -> String? {
        let busy = building(sims)
        if !busy.isEmpty {
            let others = sims.filter { !busy.contains($0.udid) }
            for sim in sims where busy.contains(sim.udid) { log("shut down all simulators", sim, "skipped: building") }
            let failed = others.compactMap { shutdownSim($0, force: true) }.count
            let kept = sims.filter { busy.contains($0.udid) }.map(\.name).joined(separator: ", ")
            return failed > 0 ? "Couldn't shut down \(failed) simulator\(failed == 1 ? "" : "s")"
                : "Shut down \(others.count), left \(kept) building"
        }
        let r = Shell.run("/usr/bin/xcrun", ["simctl", "shutdown", "all"])
        for sim in sims { log("shut down all simulators", sim, simctlError(r)) }
        return r?.status == 0 ? "All simulators shut down" : "Couldn't shut down simulators"
    }

    private static func building(_ sims: [Sim]) -> Set<String> {
        var fresh = sims.map { Sim(udid: $0.udid, name: $0.name) }
        Engine.attachUsage(&fresh)
        return Set(fresh.filter(\.usage.building).map(\.udid))
    }

    private static func simctlError(_ r: Shell.Result?) -> String? {
        guard let r else { return "couldn't run simctl" }
        guard r.status != 0 else { return nil }
        return r.errText.split(separator: "\n").last.map(String.init) ?? "simctl exit \(r.status)"
    }

    private static func log(_ action: String, _ sim: Sim, _ result: String?) {
        ActionLog.record(action, title: sim.name,
                         target: ["name": sim.name, "udid": sim.udid, "project": sim.usage.project ?? "",
                                  "apps": sim.usage.apps.map(\.name).joined(separator: ", ")],
                         result: result)
    }

    /// Kills a watched process, re-checking it is still the same program first (pids get reused).
    static func kill(_ p: DevProc, children: [DevProc] = [], action named: String? = nil) -> String? {
        let action = named ?? (p.stale ? "kill stale process" : "kill process")
        let killed = (children + [p]).filter { terminate($0, action: action) }.count
        return killed > 0 ? nil : "Process \(p.pid) was already gone"
    }

    static func killAll(_ procs: [DevProc], action: String) -> String? {
        let n = procs.filter { terminate($0, action: action) }.count
        return "Killed \(n) process\(n == 1 ? "" : "es")"
    }

    private static func terminate(_ p: DevProc, action: String) -> Bool {
        let ok: Bool, result: String?, footprint: UInt64?
        if sameProcess(p) {
            footprint = MemoryProbe.footprint(p.pid) ?? p.rssBytes
            ok = Darwin.kill(p.pid, SIGTERM) == 0
            result = ok ? nil : String(cString: strerror(errno))
        } else {
            (ok, result, footprint) = (false, "already gone", nil)
        }
        ActionLog.record(action, title: "\(p.name) (pid \(p.pid))",
                         target: ["name": p.name, "pid": "\(p.pid)", "kind": p.kind, "folder": p.cwd,
                                  "stale": "\(p.stale)", "parentPid": "\(p.ppid)"],
                         result: result, memoryFreed: ok ? footprint.map(Int64.init) : nil)
        return ok
    }

    private static func sameProcess(_ p: DevProc) -> Bool {
        guard let path = Engine.execPath(p.pid) else { return false }
        return (path as NSString).lastPathComponent == p.name
    }

    static func deleteDerived(_ entries: [DerivedEntry], root: String) -> String? {
        var n = 0, total: Int64 = 0
        for e in entries {
            let before = Engine.disk().0
            var failure: String?
            // only ever delete direct children of the DerivedData folder
            if (e.path as NSString).deletingLastPathComponent != root {
                failure = "skipped: not inside \(Paths.abbreviate(root))"
            } else {
                do {
                    try FileManager.default.removeItem(atPath: e.path)
                    SizeStore.shared.forget(e.path)
                    n += 1
                } catch {
                    failure = error.localizedDescription
                }
            }
            let freed = max(0, Engine.disk().0 - before)
            total += freed
            ActionLog.record("delete build cache", title: e.title,
                             target: ["project": e.projectDir ?? "", "workspace": e.workspace ?? "",
                                      "path": e.path, "status": "\(e.status)", "idleDays": "\(e.idleDays)"],
                             result: failure, diskFreed: failure == nil ? freed : nil)
        }
        return "Deleted \(n) build cache\(n == 1 ? "" : "s"), freed \(human(bytes: total))"
    }

    /// Empties a cache folder, keeping the folder itself.
    static func clearCache(_ c: CacheInfo) -> String? {
        let fm = FileManager.default
        let before = Engine.disk().0
        let target = ["id": c.id, "name": c.name, "path": c.path]
        guard c.clearable, let items = try? fm.contentsOfDirectory(atPath: c.path) else {
            ActionLog.record("clear package cache", title: c.name, target: target, result: "nothing to clear")
            return "Nothing to clear"
        }
        var failed: [String] = []
        for i in items {
            do { try fm.removeItem(atPath: c.path + "/" + i) } catch { failed.append(error.localizedDescription) }
        }
        SizeStore.shared.forget(c.path)
        let freed = max(0, Engine.disk().0 - before)
        ActionLog.record("clear package cache", title: c.name, target: target,
                         result: failed.first.map { "\(failed.count) of \(items.count) items not removed: \($0)" },
                         diskFreed: freed)
        return "Cleared \(c.name), freed \(human(bytes: freed))"
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

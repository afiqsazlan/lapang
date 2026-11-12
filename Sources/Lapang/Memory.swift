import AppKit
import Darwin
import Foundation

// Memory: how much RAM is in use (as Activity Monitor counts it), a minute-by-minute pressure
// history, and which apps are using it.

struct MemoryUser: Identifiable {
    enum Kind { case app, simulators, other }
    let name: String
    let bytes: UInt64
    let processes: Int
    let kind: Kind
    /// The .app bundle for real apps, so Lapang can ask them to quit.
    let bundlePath: String?
    var id: String { name }
}

struct MemoryPoint: Codable, Identifiable {
    let t: Date
    let pressure: Int  // 1 normal, 2 warning, 4 critical
    let swapGB: Double
    let usedGB: Double
    var id: Date { t }
}

enum MemoryProbe {
    /// "Memory Used" in Activity Monitor: app memory + wired + compressed.
    static func used() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    /// Your processes' memory footprint (the "Memory" column in Activity Monitor), grouped by app.
    static func users(limit: Int = 8) -> [MemoryUser] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var groups: [String: (bytes: UInt64, count: Int, kind: MemoryUser.Kind, bundle: String?)] = [:]
        for pid in pids.prefix(Int(max(n, 0))) where pid > 0 {
            guard let path = Engine.execPath(pid), let bytes = footprint(pid), bytes > 0 else { continue }
            let (name, kind, bundle) = group(for: path)
            var g = groups[name] ?? (0, 0, kind, bundle)
            g.bytes += bytes
            g.count += 1
            groups[name] = g
        }
        return groups
            .map { MemoryUser(name: $0.key, bytes: $0.value.bytes, processes: $0.value.count,
                              kind: $0.value.kind, bundlePath: $0.value.bundle) }
            .sorted { $0.bytes > $1.bytes }
            .prefix(limit)
            .map { $0 }
    }

    /// Memory footprint: what the process really costs, including what was compressed or swapped out.
    static func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return r == 0 ? info.ri_phys_footprint : nil
    }

    /// Helpers count toward their app (Chrome's renderers toward Google Chrome); everything that
    /// runs inside a simulator counts toward "iOS Simulators"; command-line tools by name.
    private static func group(for path: String) -> (String, MemoryUser.Kind, String?) {
        if path.contains("/CoreSimulator/") || path.contains("/Developer/Applications/Simulator.app/")
            || path.contains("SimMetalHost") {
            return ("iOS Simulators", .simulators, nil)
        }
        if let r = path.range(of: ".app/") {
            let bundle = String(path[..<r.lowerBound]) + ".app"
            let name = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
            if name.lowercased() == "claude" && path.contains("/claude-code/") {
                return ("Claude Code sessions", .other, nil)
            }
            return (name, .app, bundle)
        }
        let exe = (path as NSString).lastPathComponent
        if exe.hasPrefix("dart") { return ("Dart and Flutter", .other, nil) }
        return (exe, .other, nil)
    }
}

/// A sample a minute, 7 days kept; the strip shows the last 24 hours.
enum MemoryHistory {
    private static let file = Paths.support + "/memory.json"
    nonisolated(unsafe) private static var cache: [MemoryPoint]?
    private static let lock = NSLock()

    /// The last 24 hours, the sample before this one, and whether this one was stored.
    static func record(_ p: MemoryPoint) -> (day: [MemoryPoint], previous: MemoryPoint?, stored: Bool) {
        lock.lock(); defer { lock.unlock() }
        var points = cache ?? {
            guard let d = FileManager.default.contents(atPath: file) else { return [] }
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .secondsSince1970
            return (try? dec.decode([MemoryPoint].self, from: d)) ?? []
        }()
        let previous = points.last
        let stored = previous.map { p.t.timeIntervalSince($0.t) >= 55 } ?? true
        if stored {
            points.append(p)
            points.removeAll { p.t.timeIntervalSince($0.t) > 7 * 86400 }
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .secondsSince1970
            if let d = try? enc.encode(points) { try? d.write(to: URL(fileURLWithPath: file)) }
        }
        cache = points
        return (points.filter { p.t.timeIntervalSince($0.t) <= 86400 }, previous, stored)
    }

    /// Every stored sample, up to 7 days.
    static func all() -> [MemoryPoint] {
        lock.lock(); defer { lock.unlock() }
        if let cache { return cache }
        guard let d = FileManager.default.contents(atPath: file) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode([MemoryPoint].self, from: d)) ?? []
    }

    /// Share of samples in the window that were under pressure (warning or worse).
    static func pressuredShare(_ points: [MemoryPoint]) -> Double? {
        guard points.count >= 10 else { return nil }
        return Double(points.filter { $0.pressure >= 2 }.count) / Double(points.count)
    }
}

enum MemoryActions {
    /// Asks a running app to quit, the same as choosing Quit from its menu (it can still ask to save).
    static func quit(bundlePath: String) -> String? {
        let name = ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == bundlePath }
        // what it was using, helpers included; the app can still refuse to quit, so this is an upper bound
        let footprint = running.isEmpty ? nil : bundleFootprint(bundlePath)
        let asked = running.filter { $0.terminate() }
        ActionLog.record("quit app", title: name,
                         target: ["name": name, "bundle": bundlePath,
                                  "pids": running.map { "\($0.processIdentifier)" }.joined(separator: ",")],
                         result: running.isEmpty ? "no longer running" : (asked.isEmpty ? "quit request not delivered (it may have already quit)" : nil),
                         memoryFreed: asked.isEmpty ? nil : footprint.map(Int64.init))
        guard !running.isEmpty else { return "It's no longer running" }
        return "Asked \(name) to quit"
    }

    private static func bundleFootprint(_ bundlePath: String) -> UInt64 {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return 0 }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(n, 0))).reduce(0) { sum, pid in
            guard pid > 0, Engine.execPath(pid)?.hasPrefix(bundlePath + "/") == true else { return sum }
            return sum + (MemoryProbe.footprint(pid) ?? 0)
        }
    }

    static func isQuittable(_ bundlePath: String) -> Bool {
        guard bundlePath != Bundle.main.bundlePath else { return false }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == bundlePath }
    }
}

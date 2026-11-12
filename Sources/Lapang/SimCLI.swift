import Foundation

// `lapang sims`: disk use per simulator device, runtime and dyld cache, and the three cleanups.

extension CLI {
    static func sims(_ args: [String]) -> Int32 {
        guard let devices = SimStorage.loadDevices() else { print("Xcode's simctl isn't available."); return 1 }
        let st = SimStorage(devices: devices, runtimes: SimStorage.loadRuntimes(fresh: true))
        let yes = args.contains("--yes")
        let words = args.filter { !$0.hasPrefix("--") }
        switch words.first {
        case "erase": return simErase(st, words.dropFirst().joined(separator: " "), yes: yes)
        case "delete-unavailable": return simDeleteUnavailable(st, yes: yes)
        case "delete-runtime": return simDeleteRuntime(st, words.dropFirst().joined(separator: " "), yes: yes)
        case nil: break
        default: print("Usage: lapang sims [--json] [--all] | erase <udid|name> | delete-unavailable | delete-runtime <version|id> [--yes]"); return 2
        }
        if args.contains("--json") {
            let data = try! JSONSerialization.data(withJSONObject: simJSON(st), options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return 0
        }
        printSims(st, all: args.contains("--all"))
        return 0
    }

    /// Sizes from the app's last measurement, or du now when it hasn't measured these yet.
    static func measuredKB(_ path: String) -> Int64? {
        SizeStore.shared.kb(path) ?? (FileManager.default.fileExists(atPath: path) ? SizeStore.du(path) : nil)
    }

    static func simJSON(_ st: SimStorage) -> [String: Any] {
        func opt(_ v: Any?) -> Any { v ?? NSNull() }
        let iso = ISO8601DateFormatter()
        return [
            "devicesBytes": st.devicesBytes, "runtimesBytes": st.runtimesBytes,
            "dyldCacheKB": opt(st.dyldKB), "cachesKB": opt(measuredKB(SimStorage.userCaches)),
            "devices": st.devices.map { [
                "udid": $0.udid, "name": $0.name, "runtime": $0.runtime, "runtimeIdentifier": $0.runtimeID,
                "state": $0.state, "available": $0.available, "availabilityError": opt($0.availabilityError),
                "lastBootedAt": opt($0.lastBooted.map(iso.string(from:))),
                "dataBytes": opt($0.dataBytes), "logBytes": opt($0.logBytes),
            ] },
            "runtimes": st.runtimes.map { r -> [String: Any] in [
                "name": r.name, "identifier": r.id, "runtimeIdentifier": r.runtimeID, "version": r.version, "build": r.build,
                "bytes": r.bytes, "dyldCacheKB": opt(r.dyldKB), "deletable": r.deletable,
                "inUse": st.inUse(r), "devices": st.devices(on: r).count,
                "lastUsedAt": opt(r.lastUsed.map(iso.string(from:))),
            ] },
            "staleDyldCaches": st.staleDyld.map { ["path": $0, "kb": opt(SimStorage.dyldKB($0))] },
        ]
    }

    static func printSims(_ st: SimStorage, all: Bool) {
        let dyld = st.dyldKB
        let caches = measuredKB(SimStorage.userCaches) ?? 0
        let total = st.devicesBytes + st.runtimesBytes + ((dyld ?? 0) + caches) * 1024
        print("Simulators use \(human(bytes: total))")
        print("  devices     \(human(bytes: st.devicesBytes))  \(st.devices.count) devices, \(st.booted.count) booted")
        print("  runtimes    \(human(bytes: st.runtimesBytes))  \(st.runtimes.count) installed")
        print("  dyld cache  \(human(kb: dyld))  rebuilt by Xcode; deleting it needs admin")
        if caches > 1024 { print("  caches      \(human(kb: caches))  \(Paths.abbreviate(SimStorage.userCaches))") }

        let used = all ? st.devices : st.devices.filter { $0.lastBooted != nil || $0.bytes > 64 << 20 || $0.booted || !$0.available }
        let rest = st.devices.filter { d in !used.contains { $0.udid == d.udid } }
        print("")
        let rows = used.map { d -> [String] in
            let state = d.available ? d.state : "Unavailable"
            return [d.name, d.runtime, state, d.lastBooted.map { whenText($0) } ?? "never", human(bytes: d.bytes), d.udid]
        }
        printTable(["DEVICE", "RUNTIME", "STATE", "LAST BOOTED", "SIZE", "UDID"], rows, rightAligned: [4])
        if !rest.isEmpty {
            print("  + \(rest.count) never booted, \(human(bytes: rest.reduce(0) { $0 + $1.bytes })) (--all lists them)")
        }

        if !st.runtimes.isEmpty {
            print("")
            let rows = st.runtimes.map { r -> [String] in
                let status = st.inUse(r) ? "in use" : (r.deletable ? "deletable" : "kept")
                return [r.name, r.build, human(bytes: r.bytes), human(kb: r.dyldKB),
                        "\(st.devices(on: r).count)", r.lastUsed.map { whenText($0) } ?? "never", status]
            }
            printTable(["RUNTIME", "BUILD", "SIZE", "DYLD", "DEVICES", "LAST USED", ""], rows, rightAligned: [2, 3, 4])
        }
        let stale = st.staleDyld
        if !stale.isEmpty {
            let kb = stale.compactMap(SimStorage.dyldKB).reduce(0, +)
            print("  dyld caches from an older macOS: \(human(kb: kb)) in \(stale.map(Paths.abbreviate).joined(separator: ", ")) (sudo rm -rf to remove)")
        }

        print("")
        print("Device sizes are simctl's, which count APFS clones once; du counts them in full and reads higher.")
        print("Cleanups (dry runs unless --yes; booted devices and runtimes in use are never touched):")
        print("  lapang sims erase <udid|name>          reset a shut-down device to factory content")
        print("  lapang sims delete-unavailable         remove devices whose runtime is gone\(st.unavailable.isEmpty ? " (none now)" : " (\(st.unavailable.count) now)")")
        print("  lapang sims delete-runtime <version>   remove a runtime image (devices on it become unavailable)")
    }

    static func printTable(_ head: [String], _ rows: [[String]], rightAligned: Set<Int> = []) {
        let widths = head.indices.map { i in ([head[i]] + rows.map { $0[i] }).map(\.count).max() ?? 0 }
        func line(_ cells: [String]) -> String {
            "  " + cells.indices.map { i in
                let pad = String(repeating: " ", count: widths[i] - cells[i].count)
                return rightAligned.contains(i) ? pad + cells[i] : cells[i] + pad
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }
        print(line(head))
        for r in rows { print(line(r)) }
    }

    static func simErase(_ st: SimStorage, _ query: String, yes: Bool) -> Int32 {
        guard !query.isEmpty else { print("Usage: lapang sims erase <udid|name> [--yes]"); return 2 }
        let matches = st.devices.filter { $0.udid.caseInsensitiveCompare(query) == .orderedSame || $0.name.caseInsensitiveCompare(query) == .orderedSame }
        guard let d = matches.first else { print("No simulator with udid or name \"\(query)\". `lapang sims --all` lists them."); return 1 }
        if matches.count > 1 {
            print("\(matches.count) simulators are named \"\(query)\". Pass the udid:")
            for m in matches { print("  \(m.udid)  \(m.runtime)  \(m.state)  \(human(bytes: m.bytes))") }
            return 1
        }
        if let refusal = SimActions.eraseRefusal(d) { print("Not erasing: \(refusal)."); return 1 }
        guard yes else {
            print("Would erase \(d.name) (\(d.runtime), \(d.udid)): \(human(bytes: d.bytes)) of apps, data and settings,"
                + " last booted \(d.lastBooted.map { whenText($0) } ?? "never"). The device stays, empty, as if just created.")
            print("Run again with --yes to do it.")
            return 0
        }
        print(SimActions.erase(d) ?? "Done")
        return 0
    }

    static func simDeleteUnavailable(_ st: SimStorage, yes: Bool) -> Int32 {
        let list = st.unavailable
        guard !list.isEmpty else { print("No unavailable simulators."); return 0 }
        guard yes else {
            print("Would delete \(list.count) unavailable simulator\(list.count == 1 ? "" : "s"), \(human(bytes: list.reduce(0) { $0 + $1.bytes })):")
            for d in list { print("  - \(d.name) (\(d.runtime)): \(d.availabilityError ?? "unavailable"), \(human(bytes: d.bytes))") }
            print("Run again with --yes to do it (xcrun simctl delete unavailable).")
            return 0
        }
        print(SimActions.deleteUnavailable() ?? "Done")
        return 0
    }

    static func simDeleteRuntime(_ st: SimStorage, _ query: String, yes: Bool) -> Int32 {
        guard !query.isEmpty else { print("Usage: lapang sims delete-runtime <version|identifier> [--yes]"); return 2 }
        let q = query.lowercased()
        let matches = st.runtimes.filter {
            [$0.version, $0.name, $0.id, $0.build, $0.runtimeID].map { $0.lowercased() }.contains(q)
        }
        guard let r = matches.first else {
            print("No runtime \"\(query)\". Installed: " + st.runtimes.map { "\($0.name) (\($0.id))" }.joined(separator: ", "))
            return 1
        }
        if matches.count > 1 {
            print("\"\(query)\" matches \(matches.count) runtimes. Pass the identifier:")
            for m in matches { print("  \(m.id)  \(m.name) \(m.build)") }
            return 1
        }
        if let refusal = SimActions.runtimeRefusal(r) { print("Not deleting: \(refusal)."); return 1 }
        guard yes else {
            let on = st.devices(on: r)
            print("Would delete the \(r.name) runtime (\(r.build)), \(human(bytes: r.bytes)), last used \(r.lastUsed.map { whenText($0) } ?? "never").")
            if !on.isEmpty {
                print("Its \(on.count) device\(on.count == 1 ? "" : "s") (\(human(bytes: on.reduce(0) { $0 + $1.bytes }))) become unavailable; `lapang sims delete-unavailable` removes them after.")
            }
            print("Xcode can download it again (Settings › Components). Run again with --yes to do it.")
            return 0
        }
        print(SimActions.deleteRuntime(r) ?? "Done")
        return 0
    }
}

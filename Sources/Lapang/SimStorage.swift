import Foundation

// What iOS simulators take up on disk: each device's data, the runtimes they boot, and the dyld
// shared cache built for each runtime. Device sizes come from simctl's dataPathSize, which counts
// APFS clones once (an app installed by cloning it from a build folder adds almost nothing),
// where du counts them in full.

struct SimDevice: Identifiable {
    let udid: String
    let name: String
    let runtimeID: String
    let state: String
    let available: Bool
    let availabilityError: String?
    let lastBooted: Date?
    let dataBytes: Int64?
    let logBytes: Int64?
    var id: String { udid }
    var booted: Bool { state == "Booted" }
    var bytes: Int64 { (dataBytes ?? 0) + (logBytes ?? 0) }
    var runtime: String { SimStorage.runtimeName(runtimeID) }
}

struct SimRuntime: Identifiable {
    let id: String  // the disk image's identifier, what `simctl runtime delete` takes
    let runtimeID: String
    let version: String
    let build: String
    let bytes: Int64
    let deletable: Bool
    let lastUsed: Date?
    var name: String { SimStorage.runtimeName(runtimeID) }
    var dyldPath: String { SimStorage.dyldRoot + "/" + SimStorage.macBuild + "/" + runtimeID + "." + build }
    var dyldKB: Int64? { SimStorage.dyldKB(dyldPath) }
}

struct SimStorage {
    var devices: [SimDevice]
    var runtimes: [SimRuntime]

    static let devicesRoot = Paths.home + "/Library/Developer/CoreSimulator/Devices"
    static let userCaches = Paths.home + "/Library/Developer/CoreSimulator/Caches"
    static let dyldRoot = "/Library/Developer/CoreSimulator/Caches/dyld"
    static let macBuild: String = {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &buf, &size, nil, 0)
        return String(cString: buf)
    }()

    var booted: [SimDevice] { devices.filter(\.booted) }
    var unavailable: [SimDevice] { devices.filter { !$0.available } }
    var devicesBytes: Int64 { devices.reduce(0) { $0 + $1.bytes } }
    var runtimesBytes: Int64 { runtimes.reduce(0) { $0 + $1.bytes } }
    var dyldKB: Int64? { Self.dyldKB(Self.dyldRoot) }
    var cachesKB: Int64? { SizeStore.shared.kb(Self.userCaches) }
    var totalBytes: Int64 { devicesBytes + runtimesBytes + ((dyldKB ?? 0) + (cachesKB ?? 0)) * 1024 }

    func devices(on r: SimRuntime) -> [SimDevice] { devices.filter { $0.runtimeID == r.runtimeID } }

    /// Deleting a runtime shuts down whatever is booted on it, so a runtime in use is never offered.
    func inUse(_ r: SimRuntime) -> Bool { devices(on: r).contains(where: \.booted) }

    /// dyld caches built for an older macOS: Xcode makes new ones after each update and leaves these.
    var staleDyld: [String] {
        let builds = (try? FileManager.default.contentsOfDirectory(atPath: Self.dyldRoot)) ?? []
        return builds.filter { $0 != Self.macBuild && !$0.hasPrefix(".") }.map { Self.dyldRoot + "/" + $0 }
    }

    var measuredPaths: [String] { [Self.userCaches] }

    /// The dyld caches are a handful of large files, so du on them is instant and runs with the runtime list.
    nonisolated(unsafe) private static var dyldSizes: [String: Int64] = [:]

    static func dyldKB(_ path: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return dyldSizes[path]
    }

    static func useDemoDyld(_ sizes: [String: Int64]) {
        lock.lock(); defer { lock.unlock() }
        dyldSizes = sizes
    }

    private static func measureDyld(_ runtimes: [SimRuntime]) {
        let fm = FileManager.default
        let builds = (try? fm.contentsOfDirectory(atPath: dyldRoot)) ?? []
        let paths = [dyldRoot] + builds.map { dyldRoot + "/" + $0 } + runtimes.map(\.dyldPath)
        var out: [String: Int64] = [:]
        for p in paths where fm.fileExists(atPath: p) { out[p] = SizeStore.du(p) }
        lock.lock(); defer { lock.unlock() }
        dyldSizes = out
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-17-2" → "iOS 17.2"
    static func runtimeName(_ id: String) -> String {
        let last = id.split(separator: ".").last.map(String.init) ?? id
        var parts = last.split(separator: "-").map(String.init)
        guard parts.count > 1 else { return last }
        var platform = parts.removeFirst()
        if platform == "xrOS" { platform = "visionOS" }
        return platform + " " + parts.joined(separator: ".")
    }

    // MARK: Loading

    private struct DeviceList: Decodable {
        struct Device: Decodable {
            let udid: String
            let name: String
            let state: String
            let isAvailable: Bool?
            let availabilityError: String?
            let lastBootedAt: String?
            let dataPathSize: Int64?
            let logPathSize: Int64?
        }
        let devices: [String: [Device]]
    }

    private struct RuntimeImage: Decodable {
        let identifier: String
        let runtimeIdentifier: String
        let version: String
        let build: String
        let sizeBytes: Int64?
        let deletable: Bool?
        let lastUsedAt: String?
    }

    static func loadDevices() -> [SimDevice]? {
        guard let r = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"]), r.status == 0,
              let list = try? JSONDecoder().decode(DeviceList.self, from: r.out)
        else { return nil }
        let iso = ISO8601DateFormatter()
        return list.devices.flatMap { runtimeID, devices in
            devices.map { d in
                SimDevice(udid: d.udid, name: d.name, runtimeID: runtimeID, state: d.state,
                          available: d.isAvailable ?? true, availabilityError: d.availabilityError,
                          lastBooted: d.lastBootedAt.flatMap(iso.date(from:)),
                          dataBytes: d.dataPathSize, logBytes: d.logPathSize)
            }
        }
        .sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedRuntimes: (at: Date, list: [SimRuntime])?

    /// Runtime disk images change rarely and listing them takes a second, so it's kept 10 minutes.
    static func loadRuntimes(fresh: Bool = false) -> [SimRuntime] {
        lock.lock()
        if !fresh, let c = cachedRuntimes, Date().timeIntervalSince(c.at) < 600 { lock.unlock(); return c.list }
        lock.unlock()
        guard let r = Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"]), r.status == 0,
              let images = try? JSONDecoder().decode([String: RuntimeImage].self, from: r.out)
        else { return [] }
        let iso = ISO8601DateFormatter()
        let list = images.values.map {
            SimRuntime(id: $0.identifier, runtimeID: $0.runtimeIdentifier, version: $0.version, build: $0.build,
                       bytes: $0.sizeBytes ?? 0, deletable: $0.deletable ?? false,
                       lastUsed: $0.lastUsedAt.flatMap(iso.date(from:)))
        }
        .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        measureDyld(list)
        lock.lock()
        cachedRuntimes = (Date(), list)
        lock.unlock()
        return list
    }

    static func forgetRuntimes() {
        lock.lock(); defer { lock.unlock() }
        cachedRuntimes = nil
    }
}

// MARK: - Actions

/// Each re-reads simctl right before acting, so a device booted since the panel last looked is left alone.
enum SimActions {
    static func eraseRefusal(_ d: SimDevice) -> String? {
        guard let now = SimStorage.loadDevices()?.first(where: { $0.udid == d.udid }) else { return "\(d.name) is gone" }
        if now.state != "Shutdown" { return "\(d.name) is \(now.state.lowercased()); shut it down first" }
        return nil
    }

    static func erase(_ d: SimDevice) -> String? {
        if let refusal = eraseRefusal(d) {
            log("erase simulator", d, refusal, freed: nil)
            return refusal
        }
        let before = Engine.disk().0
        let r = Shell.run("/usr/bin/xcrun", ["simctl", "erase", d.udid])
        let error = simctlError(r)
        let freed = max(0, Engine.disk().0 - before)
        log("erase simulator", d, error, freed: error == nil ? freed : nil)
        return error.map { "Couldn't erase \(d.name): \($0)" } ?? "Erased \(d.name), freed \(human(bytes: freed))"
    }

    static func deleteUnavailable() -> String? {
        let gone = SimStorage.loadDevices()?.filter { !$0.available } ?? []
        guard !gone.isEmpty else { return "No unavailable simulators" }
        let before = Engine.disk().0
        let r = Shell.run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"])
        let error = simctlError(r)
        let freed = max(0, Engine.disk().0 - before)
        for d in gone { log("delete unavailable simulator", d, error, freed: nil) }
        return error.map { "Couldn't delete unavailable simulators: \($0)" }
            ?? "Deleted \(gone.count) unavailable simulator\(gone.count == 1 ? "" : "s"), freed \(human(bytes: freed))"
    }

    static func runtimeRefusal(_ rt: SimRuntime) -> String? {
        guard rt.deletable else { return "\(rt.name) can't be deleted with simctl" }
        guard let devices = SimStorage.loadDevices() else { return "couldn't list simulators" }
        let booted = devices.filter { $0.runtimeID == rt.runtimeID && $0.state != "Shutdown" }
        if !booted.isEmpty { return "\(booted.map(\.name).joined(separator: ", ")) \(booted.count == 1 ? "is" : "are") running on \(rt.name)" }
        return nil
    }

    static func deleteRuntime(_ rt: SimRuntime) -> String? {
        let target = ["runtime": rt.runtimeID, "identifier": rt.id, "build": rt.build,
                      "bytes": "\(rt.bytes)", "lastUsed": rt.lastUsed.map { ISO8601DateFormatter().string(from: $0) } ?? ""]
        if let refusal = runtimeRefusal(rt) {
            ActionLog.record("delete simulator runtime", title: rt.name, target: target, result: refusal)
            return refusal
        }
        let before = Engine.disk().0
        let r = Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "delete", rt.id])
        let error = simctlError(r)
        SimStorage.forgetRuntimes()
        let freed = max(0, Engine.disk().0 - before)
        ActionLog.record("delete simulator runtime", title: rt.name, target: target, result: error,
                         diskFreed: error == nil ? freed : nil)
        return error.map { "Couldn't delete \(rt.name): \($0)" } ?? "Deleted \(rt.name)"
    }

    private static func simctlError(_ r: Shell.Result?) -> String? {
        guard let r else { return "couldn't run simctl" }
        guard r.status != 0 else { return nil }
        return r.errText.split(separator: "\n").last.map(String.init) ?? "simctl exit \(r.status)"
    }

    private static func log(_ action: String, _ d: SimDevice, _ result: String?, freed: Int64?) {
        ActionLog.record(action, title: "\(d.name) (\(d.runtime))",
                         target: ["name": d.name, "udid": d.udid, "runtime": d.runtimeID,
                                  "bytes": "\(d.bytes)", "availability": d.availabilityError ?? ""],
                         result: result, diskFreed: freed)
    }
}

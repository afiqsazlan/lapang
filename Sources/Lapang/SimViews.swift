import SwiftUI

/// "3 h ago", "12 days ago", "Apr 2025", "never".
func whenText(_ d: Date?) -> String {
    guard let d else { return "never" }
    let s = Date().timeIntervalSince(d)
    if s < 3600 { return s < 120 ? "just now" : "\(Int(s / 60)) min ago" }
    if s < 86400 { return "\(Int(s / 3600)) h ago" }
    if s < 2 * 86400 { return "yesterday" }
    if s < 30 * 86400 { return "\(Int(s / 86400)) days ago" }
    return d.formatted(.dateTime.month(.abbreviated).year())
}

extension SimStorage {
    static let runtimeIdleDays = 90

    /// Runtimes nothing has used in a while, nothing booted needs, and simctl can delete.
    var idleRuntimes: [SimRuntime] {
        runtimes.filter { r in
            r.deletable && !inUse(r)
                && (r.lastUsed.map { Date().timeIntervalSince($0) > Double(Self.runtimeIdleDays) * 86400 } ?? true)
        }
    }

    func device(_ udid: String) -> SimDevice? { devices.first { $0.udid == udid } }
}

extension SimDevice {
    var lastBootedSort: Date { lastBooted ?? .distantPast }
    var stateText: String { available ? (booted ? "Booted" : (state == "Shutdown" ? "Shut down" : state)) : "Unavailable" }

    var eraseConfirm: Monitor.Confirm {
        .init(title: "Erase \(name)?",
              message: "\(runtime), \(human(bytes: bytes)). Deletes its apps, data and settings; the device stays, empty, as if just created.",
              button: "Erase")
    }
}

extension SimRuntime {
    var dyldSort: Int64 { dyldKB ?? -1 }
    var lastUsedSort: Date { lastUsed ?? .distantPast }

    func deleteConfirm(_ st: SimStorage) -> Monitor.Confirm {
        let on = st.devices(on: self)
        var msg = "\(human(bytes: bytes)), last used \(whenText(lastUsed))."
        if !on.isEmpty { msg += " Its \(on.count) device\(on.count == 1 ? "" : "s") become unavailable, to delete after." }
        msg += " Xcode can download it again from Settings › Components."
        return .init(title: "Delete the \(name) runtime?", message: msg, button: "Delete")
    }
}

func unavailableConfirm(_ list: [SimDevice]) -> Monitor.Confirm {
    .init(title: "Delete \(list.count) unavailable simulator\(list.count == 1 ? "" : "s")?",
          message: "Their runtime is gone, so they can't boot. \(human(bytes: list.reduce(0) { $0 + $1.bytes })).",
          button: "Delete")
}

struct SimFold: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot

    var body: some View {
        let sims = s.sims ?? []
        let st = s.simStorage
        let running = sims.isEmpty ? "None running" : "\(sims.count) running"
        Fold("Simulators", icon: "iphone", value: st.map { "\(running) · \(human(bytes: $0.totalBytes))" } ?? running) {
            if let st {
                storage(sims, st)
            } else {
                if sims.isEmpty {
                    Text("None booted").font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
                }
                ForEach(sims) { sim in runningRow(sim, nil) }
            }
        }
    }

    @ViewBuilder
    func storage(_ sims: [Sim], _ st: SimStorage) -> some View {
        let idle = st.devices.filter { !$0.booted && $0.available }
        let largest = Array(idle.filter { $0.bytes >= 100 << 20 }.prefix(3))
        let more = idle.filter { d in !largest.contains { $0.udid == d.udid } }
        let shutDown = idle + st.unavailable
        if !sims.isEmpty {
            GroupLabel(text: "Running", value: human(bytes: st.booted.reduce(0) { $0 + $1.bytes }))
            ForEach(sims) { sim in runningRow(sim, st.device(sim.udid)) }
        }
        if !shutDown.isEmpty {
            GroupLabel(text: "Shut down", value: human(bytes: shutDown.reduce(0) { $0 + $1.bytes }))
            ForEach(largest) { d in
                ItemRow(title: d.name, subtitle: "\(d.runtime) · booted \(whenText(d.lastBooted))") { hovering in
                    SizeAndAction(bytes: d.bytes) { SimEraseAction(d: d, visible: hovering) }
                }
            }
        }
        if !more.isEmpty {
            ItemRow(title: largest.isEmpty ? "\(more.count) device\(more.count == 1 ? "" : "s")" : "+ \(more.count) more device\(more.count == 1 ? "" : "s")",
                    subtitle: "\(more.filter { $0.lastBooted == nil }.count) never booted") { _ in
                SizeAndAction(bytes: more.reduce(0) { $0 + $1.bytes }) { Color.clear.frame(width: 22, height: 1) }
            }
        }
        if !st.unavailable.isEmpty {
            let list = st.unavailable
            ItemRow(title: "\(list.count) unavailable", subtitle: "Runtime gone, can't boot", tags: []) { hovering in
                SizeAndAction(bytes: list.reduce(0) { $0 + $1.bytes }) { UnavailableAction(list: list, visible: hovering) }
            }
        }
        if !st.runtimes.isEmpty {
            let dyld = st.dyldKB.map { " + \(human(kb: $0)) dyld" } ?? ""
            GroupLabel(text: "Runtimes", value: human(bytes: st.runtimesBytes) + dyld)
            ForEach(st.runtimes) { r in
                ItemRow(title: r.name, subtitle: "+ \(human(kb: r.dyldKB)) dyld · used \(whenText(r.lastUsed))",
                        tags: st.inUse(r) ? ["in use"] : []) { hovering in
                    SizeAndAction(bytes: r.bytes) { RuntimeAction(r: r, st: st, visible: hovering) }
                }
            }
        }
        if let kb = st.cachesKB, kb >= 50 << 10 {
            ItemRow(title: "Simulator caches", subtitle: "CoreSimulator/Caches") { _ in
                SizeAndAction(bytes: kb * 1024) { Color.clear.frame(width: 22, height: 1) }
            }
        }
        Text("Sizes from simctl, APFS clones counted once. The dyld cache is rebuilt by Xcode and needs admin to delete.")
            .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
    }

    func runningRow(_ sim: Sim, _ d: SimDevice?) -> some View {
        ItemRow(title: sim.name, subtitle: sim.usage.summary ?? d.map { "\($0.runtime) · no app of yours running" },
                tags: sim.usage.projectGone ? ["project gone"] : [], help: sim.usage.detail) { hovering in
            if let d {
                SizeAndAction(bytes: d.bytes) { SimAction(sim: sim, visible: hovering) }
            } else {
                SimAction(sim: sim, visible: hovering)
            }
        }
    }
}

private struct GroupLabel: View {
    let text: String
    var value: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(text)
            Spacer(minLength: 6)
            if let value {
                Text(value).monospacedDigit()
                Color.clear.frame(width: 22, height: 1)
            }
        }
        .font(.caption).foregroundStyle(.tertiary).padding(.top, 6).padding(.bottom, 1)
    }
}

private struct SizeAndAction<Action: View>: View {
    let bytes: Int64
    @ViewBuilder let action: () -> Action
    var body: some View {
        HStack(spacing: 6) {
            Text(human(bytes: bytes)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            action()
        }
    }
}

struct SimEraseAction: View {
    @EnvironmentObject var m: Monitor
    let d: SimDevice
    var visible = true

    var body: some View {
        if d.booted || !d.available {
            Color.clear.frame(width: 22, height: 1)
        } else {
            HoverAction(key: "erase-\(d.udid)", icon: "eraser", help: "Erase contents and settings", visible: visible) {
                m.act("erase-\(d.udid)", confirm: d.eraseConfirm) { SimActions.erase(d) }
            }
        }
    }
}

struct RuntimeAction: View {
    @EnvironmentObject var m: Monitor
    let r: SimRuntime
    let st: SimStorage
    var visible = true

    var body: some View {
        if st.inUse(r) {
            Image(systemName: "lock").foregroundStyle(.tertiary).frame(width: 22)
                .help("A booted simulator runs on \(r.name); shut it down to delete the runtime")
        } else if !r.deletable {
            Color.clear.frame(width: 22, height: 1)
        } else {
            HoverAction(key: "rt-\(r.id)", icon: "trash", help: "Delete runtime", visible: visible) {
                m.act("rt-\(r.id)", confirm: r.deleteConfirm(st)) { SimActions.deleteRuntime(r) }
            }
        }
    }
}

struct UnavailableAction: View {
    @EnvironmentObject var m: Monitor
    let list: [SimDevice]
    var visible = true

    var body: some View {
        HoverAction(key: "sim-unavailable", icon: "trash", help: "Delete unavailable simulators", visible: visible) {
            m.act("sim-unavailable", confirm: unavailableConfirm(list)) { SimActions.deleteUnavailable() }
        }
    }
}

struct SimulatorsPage: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot
    @State private var order = [KeyPathComparator(\SimDevice.bytes, order: .reverse)]
    @State private var runtimeOrder = [KeyPathComparator(\SimRuntime.version, order: .reverse)]

    var body: some View {
        let sims = s.sims ?? []
        let st = s.simStorage ?? SimStorage(devices: [], runtimes: [])
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 28) {
                Total(label: "In all", value: human(bytes: st.totalBytes), note: "devices, runtimes, dyld")
                Total(label: "Devices", value: human(bytes: st.devicesBytes), note: "\(st.devices.count), \(sims.count) booted")
                Total(label: "Runtimes", value: human(bytes: st.runtimesBytes), note: "\(st.runtimes.count) installed")
                Total(label: "dyld cache", value: human(kb: st.dyldKB), note: "rebuilt by Xcode")
                Spacer()
            }
            Table(st.devices.sorted(using: order), sortOrder: $order) {
                TableColumn("Device", value: \.name) { d in
                    let sim = sims.first { $0.udid == d.udid }
                    HStack(spacing: 5) {
                        Text(d.name)
                        if sim?.usage.projectGone == true { Tag(text: "project gone", color: .secondary) }
                    }
                    .help(sim?.usage.detail ?? d.udid)
                }
                .width(min: 140, ideal: 190)
                TableColumn("Runtime", value: \.runtimeID) { d in Text(d.runtime) }
                    .width(min: 60, ideal: 80, max: 110)
                TableColumn("State", value: \.stateText) { d in
                    Text(d.stateText).foregroundStyle(d.booted ? .primary : .secondary)
                        .help(d.availabilityError ?? "")
                }
                .width(min: 60, ideal: 80, max: 100)
                TableColumn("Running") { d in
                    Text(sims.first { $0.udid == d.udid }?.usage.summary ?? "").foregroundStyle(.secondary)
                }
                TableColumn("Last booted", value: \.lastBootedSort) { d in
                    Text(whenText(d.lastBooted)).foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 90, max: 110)
                TableColumn("Size", value: \.bytes) { d in Num(text: human(bytes: d.bytes)) }
                    .width(min: 60, ideal: 70, max: 90)
                TableColumn("") { d in
                    if let sim = sims.first(where: { $0.udid == d.udid }) { SimAction(sim: sim).environmentObject(m) } else { SimEraseAction(d: d).environmentObject(m) }
                }
                .width(28)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            if !st.runtimes.isEmpty {
                Table(st.runtimes.sorted(using: runtimeOrder), sortOrder: $runtimeOrder) {
                    TableColumn("Runtime", value: \.version) { r in
                        HStack(spacing: 5) {
                            Text(r.name)
                            if st.inUse(r) { Tag(text: "in use", color: .secondary) }
                        }
                    }
                    .width(min: 100, ideal: 140)
                    TableColumn("Build", value: \.build) { r in Text(r.build).foregroundStyle(.secondary) }
                        .width(min: 60, ideal: 80, max: 100)
                    TableColumn("Size", value: \.bytes) { r in Num(text: human(bytes: r.bytes)) }
                        .width(min: 60, ideal: 70, max: 90)
                    TableColumn("dyld cache", value: \.dyldSort) { r in Num(text: human(kb: r.dyldKB)) }
                        .width(min: 60, ideal: 80, max: 100)
                    TableColumn("Devices") { r in Num(text: "\(st.devices(on: r).count)") }
                        .width(min: 50, ideal: 60, max: 80)
                    TableColumn("Last used", value: \.lastUsedSort) { r in Text(whenText(r.lastUsed)).foregroundStyle(.secondary) }
                        .width(min: 70, ideal: 90, max: 120)
                    TableColumn("") { r in RuntimeAction(r: r, st: st).environmentObject(m) }
                        .width(28)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
                .frame(height: CGFloat(34 + 26 * st.runtimes.count))
            }
            HStack(spacing: 10) {
                if sims.count > 1 {
                    Button("Shut down all \(sims.count)") { m.act("sims") { Actions.shutdownAllSims(sims) } }
                        .disabled(m.running.contains("sims"))
                }
                if !st.unavailable.isEmpty {
                    let list = st.unavailable
                    Button("Delete \(list.count) unavailable") {
                        m.act("sim-unavailable", confirm: unavailableConfirm(list)) { SimActions.deleteUnavailable() }
                    }
                    .disabled(m.running.contains("sim-unavailable"))
                }
                Spacer()
                Footnote(text: "Sizes from simctl, APFS clones counted once. Booted devices and runtimes in use are never erased or deleted.")
            }
        }
    }
}

private struct Total: View {
    let label: String
    let value: String
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
            if let note { Text(note).font(.caption).foregroundStyle(.tertiary) }
        }
    }
}

import Charts
import SwiftUI

// Layout: a header (free space, sparkline, fill rate), then "things to clean" when there are
// any, then one line per section that opens on click. Grey throughout; orange is reserved
// for "needs attention" (red when the disk is critically full).

// MARK: - Building blocks

extension Level {
    var color: Color {
        switch self {
        case .ok: return .secondary
        case .warn: return .orange
        case .crit: return .red
        }
    }
}

func toneColor(_ tone: String?) -> Color {
    switch tone {
    case "warn": return .orange
    case "bad": return .red
    case "good", "info": return .primary
    default: return .secondary
    }
}

/// Which folds start open, for renders (the README screenshot); nil means the user's own state.
private struct OpenFoldsKey: EnvironmentKey { static let defaultValue: Set<String>? = nil }
extension EnvironmentValues {
    var openFolds: Set<String>? {
        get { self[OpenFoldsKey.self] }
        set { self[OpenFoldsKey.self] = newValue }
    }
    /// Set by the window: a fold shows only its rows, as the page for its section.
    var foldAsPage: Bool {
        get { self[FoldAsPageKey.self] }
        set { self[FoldAsPageKey.self] = newValue }
    }
}
private struct FoldAsPageKey: EnvironmentKey { static let defaultValue = false }

/// One summary line (icon, title, value, chevron) that opens to show its rows.
struct Fold<Content: View>: View {
    let title: String
    let icon: String
    let value: String
    let attention: Bool
    let content: Content
    @AppStorage private var open: Bool
    @Environment(\.openFolds) private var forced
    @Environment(\.foldAsPage) private var asPage
    @State private var hovering = false

    init(_ title: String, icon: String, value: String, attention: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.value = value
        self.attention = attention
        self.content = content()
        _open = AppStorage(wrappedValue: false, "fold." + title)
    }

    var body: some View {
        if asPage {
            VStack(alignment: .leading, spacing: 0) { content }
        } else {
            folded
        }
    }

    private var folded: some View {
        let isOpen = forced.map { $0.contains(title) } ?? open
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
                    Text(title)
                    Spacer(minLength: 8)
                    if attention { Circle().fill(Color.orange).frame(width: 6, height: 6) }
                    Text(value).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 10)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(hovering ? Color.primary.opacity(0.05) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            if isOpen {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.leading, 42).padding(.trailing, 14).padding(.bottom, 8)
            }
            Divider()
        }
    }
}

/// A list row whose trailing action can depend on whether the pointer is over it.
struct ItemRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var tags: [String] = []
    var help: String? = nil
    @ViewBuilder let trailing: (Bool) -> Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                    ForEach(tags, id: \.self) { Tag(text: $0, color: .secondary) }
                }
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .help(help ?? "")
            Spacer(minLength: 6)
            trailing(hovering)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// A fixed-width text button, so stacked actions line up in one column.
struct RowButton: View {
    @EnvironmentObject var m: Monitor
    let key: String
    let title: String
    let action: () -> Void

    var body: some View {
        Group {
            if m.running.contains(key) {
                ProgressView().controlSize(.small)
            } else {
                Button(action: action) { Text(title).frame(maxWidth: .infinity) }.controlSize(.small)
            }
        }
        .frame(width: 84)
    }
}

/// An icon action shown only while its row is hovered (or while it runs).
struct HoverAction: View {
    @EnvironmentObject var m: Monitor
    let key: String
    let icon: String
    let help: String
    let visible: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if m.running.contains(key) {
                ProgressView().controlSize(.small)
            } else {
                Button(action: action) { Image(systemName: icon) }
                    .buttonStyle(.borderless).help(help)
                    .opacity(visible ? 1 : 0)
            }
        }
        .frame(width: 22)
    }
}

struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .foregroundStyle(color)
    }
}

struct Bar: View {
    let value: Double
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: max(height, g.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

struct Caption: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

// MARK: - Header

struct Header: View {
    let s: Snapshot

    var body: some View {
        let day = s.history.filter { Date().timeIntervalSince($0.t) <= 86400 }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.0f GB", s.freeGB))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(s.diskLevel == .ok ? Color.primary : s.diskLevel.color)
                Text(String(format: "free of %.0f GB", s.totalGB)).foregroundStyle(.secondary)
                Spacer()
                Button { AppDelegate.openWindow() } label: { Image(systemName: "macwindow") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Open in window (⌘0)")
            }
            Bar(value: s.usedFraction, color: s.diskLevel == .ok ? Color.secondary : s.diskLevel.color)
            if day.count >= 2 {
                Sparkline(points: day, warn: s.config.disk.warnGB, trend: s.trend)
            }
            TrendLine(s: s)
            Divider().padding(.vertical, 4)
            MemoryLine(s: s)
        }
        .padding(14)
    }
}

/// Memory sits in the header next to disk: pressure is the thing that slows a busy dev Mac down,
/// and swap is where the two meet (it lives on the disk).
struct MemoryLine: View {
    let s: Snapshot
    @State private var focus = StripFocus()
    @Environment(\.pinLatestSpike) private var pinLatestSpike

    var body: some View {
        let (label, color) = (s.pressureText, s.pressureLevel.color)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Memory").fontWeight(.medium)
                if s.pressureLevel != .ok { Circle().fill(color).frame(width: 6, height: 6) }
                Text(label).foregroundStyle(color)
                Spacer()
                Text(String(format: "%.1f of %.0f GB used", Double(s.memUsed) / 1_073_741_824,
                            Double(s.memTotal) / 1_073_741_824))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
            PressureStrip(points: s.memHistory, spikes: s.memSpikes, focus: $focus)
            if let i = focus.shown {
                Text(PressureStrip.describe(i, points: s.memHistory, spikes: s.memSpikes))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                HStack {
                    Text(historyText).foregroundStyle(.secondary)
                    Spacer()
                    Text("swap \(human(bytes: Int64(s.swapUsed))) of \(human(bytes: Int64(s.swapTotal)))")
                        .foregroundStyle(s.swapFraction > 0.8 ? Color.orange : Color.secondary).monospacedDigit()
                }
                .font(.caption)
                if let last = s.memSpikes.last, Date().timeIntervalSince(last.t) <= 2 * 3600 {
                    Text("Last spike \(last.t.formatted(date: .omitted, time: .shortened)): \(last.summary)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if s.swapFraction > 0.8 && s.diskLevel != .ok {
                Text("Swap lives on the disk and can't grow while it's this full. Freeing disk space helps memory too.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .help("Memory pressure is how hard macOS is working to find RAM. Swap is RAM spilled onto the disk.")
        .onAppear {
            if pinLatestSpike, let t = s.memSpikes.last?.t { focus.pinned = PressureStrip.slice(t, now: Date()) }
        }
    }

    var historyText: String {
        guard let share = MemoryHistory.pressuredShare(s.memHistory),
              let first = s.memHistory.first else { return "Pressure history fills in over the next hours" }
        let hours = Date().timeIntervalSince(first.t) / 3600
        let window = hours >= 20 ? "the last 24 h" : (hours >= 1 ? "the last \(Int(hours)) h" : "the last \(Int(hours * 60)) min")
        return share < 0.01 ? "No pressure in \(window)" : "Under pressure \(Int((share * 100).rounded()))% of \(window)"
    }
}

/// Which pressure slice the pointer is over, or was clicked to stay shown.
struct StripFocus {
    var hover: Int?
    var pinned: Int?
    var shown: Int? { hover ?? pinned }
}

private struct PinLatestSpikeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Renders only: start with the latest spike's slice shown.
    var pinLatestSpike: Bool {
        get { self[PinLatestSpikeKey.self] }
        set { self[PinLatestSpikeKey.self] = newValue }
    }
}

/// The last 24 hours of memory pressure in 15-minute slices, like Activity Monitor's graph:
/// grey when normal, orange under pressure, red when critical, faint where there's no data yet.
/// A dot under a slice marks a recorded spike; hovering or clicking a slice shows what caused it.
struct PressureStrip: View {
    let points: [MemoryPoint]
    var spikes: [PressureSpike] = []
    var height: CGFloat = 8
    var focus: Binding<StripFocus>?

    static let slices = 96

    static func slice(_ t: Date, now: Date) -> Int? {
        let age = now.timeIntervalSince(t)
        guard age >= 0, age < 86400 else { return nil }
        return slices - 1 - Int(age / 900)
    }

    var body: some View {
        let now = Date()
        let marked = Set(spikes.compactMap { Self.slice($0.t, now: now) })
        let shown = focus?.wrappedValue.shown
        VStack(spacing: 2) {
            Canvas { ctx, size in
                let w = size.width / CGFloat(Self.slices)
                var worst = [Int](repeating: 0, count: Self.slices)
                for p in points {
                    guard let i = Self.slice(p.t, now: now) else { continue }
                    worst[i] = max(worst[i], p.pressure)
                }
                for i in 0 ..< Self.slices {
                    let color: Color = switch worst[i] {
                    case 0: .primary.opacity(0.06)
                    case 1: .secondary.opacity(0.45)
                    case 2, 3: .orange
                    default: .red
                    }
                    ctx.fill(Path(CGRect(x: CGFloat(i) * w, y: 0, width: w + 0.5, height: size.height)), with: .color(color))
                }
                if let shown {
                    ctx.fill(Path(CGRect(x: CGFloat(shown) * w, y: 0, width: w + 0.5, height: size.height)),
                             with: .color(.primary.opacity(0.55)))
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: height / 2))
            if !marked.isEmpty {
                Canvas { ctx, size in
                    let w = size.width / CGFloat(Self.slices)
                    for i in marked {
                        let d: CGFloat = 3
                        ctx.fill(Path(ellipseIn: CGRect(x: (CGFloat(i) + 0.5) * w - d / 2, y: 0, width: d, height: d)),
                                 with: .color(i == shown ? .primary : .secondary))
                    }
                }
                .frame(height: 3)
            }
        }
        .overlay {
            if let focus {
                GeometryReader { g in
                    let index = { (x: CGFloat) in min(Self.slices - 1, max(0, Int(x / g.size.width * CGFloat(Self.slices)))) }
                    Color.clear.contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(at): focus.wrappedValue.hover = index(at.x)
                            case .ended: focus.wrappedValue.hover = nil
                            }
                        }
                        .onTapGesture(coordinateSpace: .local) { at in
                            let i = index(at.x)
                            focus.wrappedValue.pinned = focus.wrappedValue.pinned == i ? nil : i
                        }
                }
            }
        }
        .help(focus == nil ? "Memory pressure over the last 24 hours, oldest on the left" : "")
    }

    /// "2:15 – 2:30 PM · Critical · iOS Simulators +3.1 GB, Claude Code sessions +2.4 GB"
    static func describe(_ i: Int, points: [MemoryPoint], spikes: [PressureSpike], now: Date = Date()) -> String {
        let start = now.addingTimeInterval(-Double(slices - i) * 900)
        let end = start.addingTimeInterval(900)
        let range = start.formatted(date: .omitted, time: .shortened) + " – " + end.formatted(date: .omitted, time: .shortened)
        let worst = points.filter { slice($0.t, now: now) == i }.map(\.pressure).max() ?? 0
        let level = switch worst {
        case 0: "No data"
        case 1: "Normal"
        case 2, 3: "Under pressure"
        default: "Critical"
        }
        let rank: [PressureSpike.Trigger: Int] = [.critical: 3, .warn: 2, .swap: 1]
        guard let spike = spikes.filter({ slice($0.t, now: now) == i }).max(by: { rank[$0.trigger]! < rank[$1.trigger]! }) else {
            return range + " · " + level
        }
        let swap = spike.trigger == .swap ? String(format: " · swap +%.1f GB", spike.swapGrowthGB ?? 0) : ""
        return range + " · " + level + swap + " · " + spike.summary
    }
}

struct Sparkline: View {
    let points: [HistoryPoint]
    let warn: Double
    let trend: Trend

    var body: some View {
        let projection: [HistoryPoint] = {
            guard trend.state == .filling, let last = points.last else { return [] }
            let hours = min(4, trend.hoursToFull ?? 4)
            return [last, HistoryPoint(t: last.t.addingTimeInterval(hours * 3600),
                                       freeGB: max(0, last.freeGB + trend.ratePerDay / 24 * hours))]
        }()
        let top = max(points.map(\.freeGB).max() ?? 0, warn) * 1.15
        Chart {
            RuleMark(y: .value("Warn", warn))
                .foregroundStyle(Color.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            ForEach(points) { p in
                LineMark(x: .value("Time", p.t), y: .value("Free", p.freeGB), series: .value("S", "free"))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            ForEach(projection) { p in
                LineMark(x: .value("Time", p.t), y: .value("Free", p.freeGB), series: .value("S", "forecast"))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0 ... top)
        .frame(height: 34)
        .help("Free space over the last 24 hours. The dotted line is \(Int(warn)) GB; the dashed end is the forecast.")
    }
}

struct TrendLine: View {
    let s: Snapshot

    var body: some View {
        let t = s.trend
        let urgent = s.forecastWarning || s.diskLevel != .ok
        let text: String = {
            switch t.state {
            case .learning:
                let mins = Int(t.span / 60)
                return "Learning the fill rate (\(mins < 60 ? "\(mins) min" : "\(mins / 60) h") of 2 h)"
            case .steady: return "Steady over the last 24 hours"
            case .freeing: return String(format: "Freeing up %.1f GB/day", t.ratePerDay)
            case .filling:
                var line = String(format: "Filling %.1f GB/day", -t.ratePerDay)
                if let h = t.hoursToWarn, h > 0 {
                    line += " · \(Int(s.config.disk.warnGB)) GB left in \(durationText(hours: h))"
                } else if let h = t.hoursToFull {
                    line += " · full in \(durationText(hours: h))"
                }
                return line
            }
        }()
        HStack(spacing: 6) {
            if urgent { Circle().fill(s.diskLevel == .crit ? Color.red : Color.orange).frame(width: 6, height: 6) }
            Text(text).foregroundStyle(urgent ? (s.diskLevel == .crit ? Color.red : Color.orange) : Color.secondary)
            Spacer()
            if t.sinceCleanup && t.state != .learning {
                Text("since last cleanup").foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
    }
}

// MARK: - Things to clean

struct Chore: Identifiable {
    enum Kind {
        case cache(DerivedEntry)
        case process(DevProc)
        case simulators([Sim])
        case port(Listener)
        case worktrees([WorktreeUnit])
        case simRuntime(SimRuntime, SimStorage)
        case simUnavailable([SimDevice])
    }
    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let button: String
    let kind: Kind
    let kb: Int64
    var help: String? = nil
    /// Runtimes are a re-download, so Clean all leaves them to be deleted one by one.
    var inCleanAll: Bool { if case .simRuntime = kind { return false }; return true }
}

extension Snapshot {
    var chores: [Chore] { chores() }

    /// What's worth cleaning right now: orphaned or unused build caches, stale processes, running simulators.
    /// Simulators with a build aimed at them are left out unless `includeBuilding`.
    func chores(includeBuilding: Bool = false) -> [Chore] {
        var out: [Chore] = []
        let idle = config.xcode.idleDays
        for e in derived.sorted(by: { ($0.sizeKB ?? 0) > ($1.sizeKB ?? 0) }) {
            if e.status == .orphan {
                out.append(Chore(id: "dd-" + e.name, icon: "folder.badge.minus", title: e.title,
                                 subtitle: "Build cache, project gone · \(human(kb: e.sizeKB))",
                                 button: "Delete", kind: .cache(e), kb: e.sizeKB ?? 0))
            } else if e.status == .live && e.idleDays >= idle {
                out.append(Chore(id: "dd-" + e.name, icon: "folder", title: e.title,
                                 subtitle: "Build cache, unused \(e.idleDays) days · \(human(kb: e.sizeKB))",
                                 button: "Delete", kind: .cache(e), kb: e.sizeKB ?? 0))
            }
        }
        for p in procs where p.stale {
            let why = p.ppid == 1 ? "parent exited" : "folder gone"
            let kind = ProcessFold.kindName[p.kind] ?? p.name
            let place = p.cwd.split(separator: "/").suffix(2).joined(separator: "/")
            out.append(Chore(id: "kill-\(p.pid)", icon: "bolt.horizontal", title: place.isEmpty ? kind : place,
                             subtitle: "\(kind) · stale · \(human(bytes: Int64(p.rssBytes)))",
                             button: "Kill", kind: .process(p), kb: 0,
                             help: "Stale because its \(why). Killing it frees \(human(bytes: Int64(p.rssBytes))) of memory."))
        }
        for l in ports where l.folderGone && l.stoppable {
            out.append(Chore(id: "port-\(l.pid)", icon: "network.slash", title: "Port \(l.portList): \(l.kind)",
                             subtitle: "\(l.folder ?? "Its folder") deleted · \(human(bytes: Int64(l.bytes)))",
                             button: "Stop", kind: .port(l), kb: 0, help: l.help))
        }
        // merged worktrees nobody has touched: one line for all of them, details in the fold
        let idleMerged = worktrees.filter { $0.isChore(idleDays: config.worktrees.idleDays) }
            .sorted { ($0.outputKB ?? 0) > ($1.outputKB ?? 0) }
        if !idleMerged.isEmpty {
            let kb = idleMerged.reduce(Int64(0)) { $0 + ($1.outputKB ?? 0) }
            let clones = idleMerged.contains(where: \.hasClonableOutput)
            let one = idleMerged.count == 1 ? idleMerged[0] : nil
            out.append(Chore(id: "wt-clean", icon: "arrow.triangle.merge",
                             title: one.map { "\($0.group)/\($0.name)" } ?? "\(idleMerged.count) merged worktrees",
                             subtitle: "Build output, idle \(config.worktrees.idleDays)d+ · \(clones ? "up to " : "")\(human(kb: kb))",
                             button: "Clean", kind: .worktrees(idleMerged), kb: kb,
                             help: "Deletes only regenerable, git-ignored folders; the worktrees stay."
                                + (clones ? " Copy-on-write clones free less than counted." : "")))
        }
        if let all = sims, case let sims = all.filter({ includeBuilding || !$0.usage.building }), !sims.isEmpty {
            // a simulator still running an app whose folder was deleted is its own chore
            for sim in sims where sim.usage.projectGone {
                out.append(Chore(id: "sim-\(sim.udid)", icon: "iphone", title: sim.name,
                                 subtitle: "\(sim.usage.projectShort ?? "Its project") was deleted",
                                 button: "Shut down", kind: .simulators([sim]), kb: 0))
            }
            let rest = sims.filter { !$0.usage.projectGone }
            if !rest.isEmpty {
                out.append(Chore(id: "sims", icon: "iphone",
                                 title: rest.count == 1 ? "1 simulator running" : "\(rest.count) simulators running",
                                 subtitle: rest.map { s in s.usage.projectShort.map { "\(s.name) · \($0)" } ?? s.name }
                                     .joined(separator: ", "),
                                 button: "Shut down", kind: .simulators(rest), kb: 0,
                                 help: includeBuilding ? nil : all.buildingNote))
            }
        }
        if let st = simStorage {
            let gone = st.unavailable
            if !gone.isEmpty {
                let kb = gone.reduce(0) { $0 + $1.bytes } / 1024
                out.append(Chore(id: "sim-unavailable", icon: "iphone.slash",
                                 title: gone.count == 1 ? "1 unavailable simulator" : "\(gone.count) unavailable simulators",
                                 subtitle: "Runtime gone, can't boot · \(human(kb: kb))",
                                 button: "Delete", kind: .simUnavailable(gone), kb: kb))
            }
            for r in st.idleRuntimes {
                out.append(Chore(id: "rt-\(r.id)", icon: "iphone.gen1", title: "\(r.name) runtime",
                                 subtitle: "Unused since \(whenText(r.lastUsed)) · \(human(bytes: r.bytes))",
                                 button: "Delete", kind: .simRuntime(r, st), kb: r.bytes / 1024,
                                 help: "\(st.devices(on: r).count) devices use it; they become unavailable. Xcode can download it again."))
            }
        }
        return out
    }
}

struct ChoresBlock: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot
    /// In the window: a card, with Clean all beside the heading.
    var wide = false

    var body: some View {
        let chores = s.chores
        let total = chores.reduce(Int64(0)) { $0 + $1.kb }
        let bulk = chores.filter(\.inCleanAll)
        let bulkTotal = bulk.reduce(Int64(0)) { $0 + $1.kb }
        VStack(alignment: .leading, spacing: 0) {
            if chores.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    Text("Nothing to clean")
                }
                .padding(.horizontal, wide ? 0 : 14).padding(.vertical, wide ? 0 : 10)
            } else {
                HStack(spacing: 8) {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                    Text(chores.count == 1 ? "1 thing to clean" : "\(chores.count) things to clean").fontWeight(.medium)
                    Spacer()
                    if wide && bulk.count > 1 {
                        cleanAllButton(bulk, bulkTotal).frame(width: 170)
                    } else if total > 0 {
                        Text(human(kb: total)).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 4)
                ForEach(chores) { c in
                    HStack(spacing: 10) {
                        Image(systemName: c.icon).foregroundStyle(.secondary).frame(width: 18)
                        ItemRow(title: c.title, subtitle: c.subtitle, help: c.help) { _ in
                            RowButton(key: c.id, title: c.button) { run(c) }
                        }
                    }
                }
                if bulk.count > 1 && !wide {
                    cleanAllButton(bulk, bulkTotal).padding(.top, 8)
                }
            }
        }
        .padding(chores.isEmpty && !wide ? 0 : 14)
        .background(chores.isEmpty && !wide ? Color.clear : Color.primary.opacity(0.035))
        .overlay(alignment: .bottom) { if !wide { Divider() } }
        .overlay(alignment: .top) { if !wide { Divider() } }
        .clipShape(RoundedRectangle(cornerRadius: wide ? 10 : 0))
        .overlay { if wide { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)) } }
    }

    @ViewBuilder
    func cleanAllButton(_ chores: [Chore], _ total: Int64) -> some View {
        if m.running.contains("clean-all") {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        } else {
            Button { cleanAll(chores) } label: {
                Text(total > 0 ? "Clean all · \(human(kb: total))" : "Clean all").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(wide ? .orange : nil)
        }
    }

    func run(_ c: Chore) {
        let root = s.derivedDataRoot
        switch c.kind {
        case .cache(let e):
            m.act(c.id, confirm: .init(title: "Delete the build cache for \(e.title)?",
                                       message: "\(human(kb: e.sizeKB)). The next build of this project starts from scratch.",
                                       button: "Delete")) { Actions.deleteDerived([e], root: root) }
        case .process(let p):
            m.act(c.id) { Actions.kill(p) }
        case .simulators(let list):
            let all = list.count == (s.sims?.count ?? 0)
            m.act(c.id) { all ? Actions.shutdownAllSims(list) : list.compactMap { Actions.shutdownSim($0) }.first }
        case .port(let l):
            m.act(c.id, confirm: PortActions.confirm(l)) { PortActions.stop(l) }
        case .worktrees(let list):
            m.act(c.id, confirm: WorktreesFold.cleanConfirm(list)) { WorktreeActions.cleanOutput(list) }
        case .simRuntime(let r, let st):
            m.act(c.id, confirm: r.deleteConfirm(st)) { SimActions.deleteRuntime(r) }
        case .simUnavailable(let list):
            m.act(c.id, confirm: unavailableConfirm(list)) { SimActions.deleteUnavailable() }
        }
    }

    func cleanAll(_ chores: [Chore]) {
        var caches: [DerivedEntry] = [], procs: [DevProc] = [], sims: [Sim] = [], servers: [Listener] = [], trees: [WorktreeUnit] = []
        var unavailable: [SimDevice] = []
        for c in chores {
            switch c.kind {
            case .cache(let e): caches.append(e)
            case .process(let p): procs.append(p)
            case .simulators(let list): sims += list
            case .port(let l): servers.append(l)
            case .worktrees(let list): trees += list
            case .simUnavailable(let list): unavailable += list
            case .simRuntime: break
            }
        }
        var parts: [String] = []
        if !caches.isEmpty {
            parts.append("delete \(caches.count) build cache\(caches.count == 1 ? "" : "s") (\(human(kb: caches.reduce(0) { $0 + ($1.sizeKB ?? 0) })))")
        }
        if !procs.isEmpty { parts.append("kill \(procs.count) stale process\(procs.count == 1 ? "" : "es")") }
        if !servers.isEmpty {
            parts.append("stop \(servers.count) server\(servers.count == 1 ? "" : "s") whose folder was deleted (port\(servers.count == 1 ? "" : "s") \(servers.map(\.portList).joined(separator: ", ")))")
        }
        if !sims.isEmpty { parts.append("shut down the simulators") }
        if !trees.isEmpty { parts.append("delete the build output of \(trees.count) merged worktree\(trees.count == 1 ? "" : "s")") }
        if !unavailable.isEmpty { parts.append("delete \(unavailable.count) unavailable simulator\(unavailable.count == 1 ? "" : "s")") }
        let root = s.derivedDataRoot
        let deleteUnavailable = !unavailable.isEmpty
        let (toDelete, toKill, shutDown, toStop, toClean) = (caches, procs, sims, servers, trees)
        m.act("clean-all", confirm: .init(title: "Clean all?", message: "This will " + parts.joined(separator: ", ") + ".",
                                          button: "Clean all")) {
            ActionLog.$batch.withValue("clean all") {
                var msg = "Cleaned"
                if !toDelete.isEmpty, let r = Actions.deleteDerived(toDelete, root: root) { msg = r }
                if !toKill.isEmpty { _ = Actions.killAll(toKill, action: "kill stale process") }
                for sim in shutDown { _ = Actions.shutdownSim(sim) }
                for l in toStop { _ = PortActions.stop(l) }
                if !toClean.isEmpty { _ = WorktreeActions.cleanOutput(toClean) }
                if deleteUnavailable { _ = SimActions.deleteUnavailable() }
                return msg
            }
        }
    }
}

// MARK: - Folds

struct GrowthFold: View {
    let s: Snapshot
    @AppStorage("chartDays") private var days = 1

    var body: some View {
        let shown = s.history.filter { Date().timeIntervalSince($0.t) <= Double(days) * 86400 }
        Fold("What grew", icon: "chart.line.uptrend.xyaxis", value: dayChange) {
            if shown.count >= 2 {
                HStack {
                    Caption(text: "Free space")
                    Spacer()
                    Picker("", selection: $days) {
                        Text("24h").tag(1)
                        Text("7d").tag(7)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 90)
                }
                .padding(.top, 2)
                HistoryChart(points: shown, warn: s.config.disk.warnGB, days: days,
                             forecast: days == 1 ? s.trend : nil)
                    .padding(.vertical, 6)
            }
            GrowthList(s: s)
        }
    }

    /// Disk used over the last 24 hours (or as much history as there is).
    var dayChange: String {
        let now = Date()
        guard let first = s.history.first(where: { now.timeIntervalSince($0.t) <= 86400 }),
              let last = s.history.last, last.t.timeIntervalSince(first.t) >= 3600 else { return "—" }
        let used = first.freeGB - last.freeGB
        let span = now.timeIntervalSince(first.t) >= 20 * 3600 ? " in 24h" : " so far"
        if abs(used) < 0.05 { return "No change" + span }
        return String(format: "%.1f GB %@", abs(used), used > 0 ? "used" : "freed") + span
    }
}

struct HistoryChart: View {
    let points: [HistoryPoint]
    let warn: Double
    let days: Int
    let forecast: Trend?
    var height: CGFloat = 90

    var body: some View {
        let projection: [HistoryPoint] = {
            guard let f = forecast, f.state == .filling, let last = points.last else { return [] }
            let hours = min(6, f.hoursToFull ?? 6)
            return [last, HistoryPoint(t: last.t.addingTimeInterval(hours * 3600),
                                       freeGB: max(0, last.freeGB + f.ratePerDay / 24 * hours))]
        }()
        let top = max(points.map(\.freeGB).max() ?? 0, warn) * 1.25
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Time", p.t), y: .value("Free GB", p.freeGB))
                    .foregroundStyle(Color.secondary.opacity(0.12))
                LineMark(x: .value("Time", p.t), y: .value("Free GB", p.freeGB), series: .value("Series", "free"))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            ForEach(projection) { p in
                LineMark(x: .value("Time", p.t), y: .value("Free GB", p.freeGB), series: .value("Series", "forecast"))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            RuleMark(y: .value("Warn", warn))
                .foregroundStyle(Color.orange.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .chartYScale(domain: 0 ... top)
        .chartXAxis {
            if days == 1 {
                AxisMarks(values: hourTicks(points.first?.t ?? .now, (projection.last ?? points.last)?.t ?? .now, every: 6)) { _ in
                    AxisValueLabel(format: .dateTime.hour())
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 7)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine()
                AxisValueLabel { if let g = v.as(Double.self) { Text("\(Int(g))G") } }
            }
        }
        .frame(height: height)
    }
}

/// Hour marks every `step` hours of a time span, minus any so close to an end that the label
/// would be cut off by the edge or run into the y axis.
func hourTicks(_ from: Date, _ to: Date, every step: Int) -> [Date] {
    let cal = Calendar.current
    let span = to.timeIntervalSince(from)
    guard span > 0, var t = cal.nextDate(after: from, matching: DateComponents(minute: 0), matchingPolicy: .nextTime)
    else { return [] }
    var out: [Date] = []
    while t < to {
        if cal.component(.hour, from: t) % step == 0, t.timeIntervalSince(from) > span * 0.06,
           to.timeIntervalSince(t) > span * 0.12 { out.append(t) }
        t = t.addingTimeInterval(3600)
    }
    return out
}

struct GrowthList: View {
    let s: Snapshot

    var body: some View {
        if let g = s.growth {
            VStack(alignment: .leading, spacing: 4) {
                Caption(text: "Change since \(g.since.formatted(.relative(presentation: .named)))")
                if g.items.isEmpty {
                    Text("No measured folder changed by more than 50 MB.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(g.items) { i in line(i.deltaKB, i.name, i.detail, emphasis: i.deltaKB > 0) }
                if let u = g.untrackedKB, abs(u) >= 500 * 1024 {
                    line(u, "Everything else", "simulators, app data, downloads…", emphasis: false)
                }
            }
        } else if s.sizesMeasuredAt != nil {
            Text("What grew shows up after a second size check, about 30 minutes after the first.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    func line(_ kb: Int64, _ name: String, _ detail: String?, emphasis: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text((kb > 0 ? "+" : "−") + human(kb: abs(kb)))
                .monospacedDigit()
                .foregroundStyle(emphasis ? Color.primary : Color.secondary)
                .frame(width: 62, alignment: .trailing)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .font(.caption)
    }
}

struct XcodeFold: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot

    var body: some View {
        let root = s.derivedDataRoot
        Fold("Xcode build caches", icon: "hammer", value: "\(human(kb: s.derivedTotalKB)) · \(s.derived.count)") {
            ForEach(s.derived.sorted { ($0.sizeKB ?? 0) > ($1.sizeKB ?? 0) }) { e in
                let age = e.idleDays == 0 ? "built today" : "built \(e.idleDays)d ago"
                ItemRow(title: e.title, subtitle: "\(human(kb: e.sizeKB)) · \(age)", tags: e.tags(idleDays: s.config.xcode.idleDays),
                        help: e.projectDir.map(Paths.abbreviate) ?? e.name) { hovering in
                    DerivedAction(e: e, root: root, visible: hovering)
                }
            }
            SizesNote(s: s)
        }
    }
}

extension DerivedEntry {
    func tags(idleDays: Int) -> [String] {
        switch status {
        case .orphan: return ["project gone"]
        case .new: return ["building"]
        case .live: return self.idleDays >= idleDays ? ["unused"] : []
        case .protected: return []
        }
    }
}

/// A build cache's delete button, or a lock when it's protected; in the fold and the window's table.
struct DerivedAction: View {
    @EnvironmentObject var m: Monitor
    let e: DerivedEntry
    let root: String
    var visible = true

    var body: some View {
        if e.status == .protected {
            Image(systemName: "lock").foregroundStyle(.tertiary).frame(width: 22)
                .help("Protected in config.json")
        } else {
            HoverAction(key: "dd-\(e.name)", icon: "trash", help: "Delete this build cache", visible: visible) {
                m.act("dd-\(e.name)", confirm: .init(
                    title: "Delete the build cache for \(e.title)?",
                    message: "\(human(kb: e.sizeKB)). The next build of this project starts from scratch.",
                    button: "Delete")) { Actions.deleteDerived([e], root: root) }
            }
        }
    }
}

struct SizesNote: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot

    var body: some View {
        HStack(spacing: 6) {
            if m.measuring {
                ProgressView().controlSize(.mini)
                Text("Measuring folder sizes…")
            } else if let t = s.sizesMeasuredAt {
                Text("Sizes measured \(t.formatted(.relative(presentation: .named)))")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.top, 4)
    }
}

struct CachesFold: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot

    var body: some View {
        let total = s.caches.reduce(Int64(0)) { $0 + ($1.sizeKB ?? 0) }
        Fold("Package caches", icon: "shippingbox", value: human(kb: total)) {
            ForEach(s.caches.sorted { ($0.sizeKB ?? 0) > ($1.sizeKB ?? 0) }) { c in
                ItemRow(title: c.name, subtitle: human(kb: c.sizeKB) + (c.note.map { " · " + $0 } ?? ""),
                        help: Paths.abbreviate(c.path)) { hovering in
                    CacheAction(c: c, visible: hovering)
                }
            }
        }
    }
}

struct CacheAction: View {
    @EnvironmentObject var m: Monitor
    let c: CacheInfo
    var visible = true

    var body: some View {
        if c.clearable {
            HoverAction(key: "cache-\(c.id)", icon: "trash", help: "Clear", visible: visible) {
                m.act("cache-\(c.id)", confirm: .init(
                    title: "Clear the \(c.name) cache?",
                    message: "\(human(kb: c.sizeKB)) in \(Paths.abbreviate(c.path)). It refills on the next install.",
                    button: "Clear")) { Actions.clearCache(c) }
            }
        } else {
            Color.clear.frame(width: 22, height: 1)
        }
    }
}

struct ProcessFold: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot

    static let kindName = [
        "mcp": "MCP server", "lsp": "Language server", "devtools": "DevTools service",
        "compiler": "Compiler", "flutter": "flutter run",
    ]

    var body: some View {
        let mcp = s.procs.filter { $0.kind == "mcp" }
        let mcpPids = Set(mcp.map(\.pid))
        let others = s.procs.filter { $0.kind != "mcp" && !mcpPids.contains($0.ppid) }
        let total = s.procs.reduce(UInt64(0)) { $0 + $1.rssBytes }

        Fold("Dev processes", icon: "cpu", value: "\(s.procs.count) · \(human(bytes: Int64(total)))",
             attention: s.procs.contains(where: \.stale)) {
            if s.procs.isEmpty {
                Text("None running").font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(mcp) { p in
                let kids = s.procs.filter { $0.ppid == p.pid }
                let size = p.rssBytes + kids.reduce(0) { $0 + $1.rssBytes }
                let newest = mcp.count > 1 && p.pid == mcp.max(by: { $0.started < $1.started })?.pid
                let owner = p.stale ? "session gone" : (p.session ?? "")
                let tags = (p.stale ? ["stale"] : []) + (p.idleTag.map { [$0] } ?? []) + (newest ? ["newest"] : [])
                ItemRow(title: kids.isEmpty ? "\(p.name) MCP server" : "\(p.name) MCP + language server",
                        subtitle: [owner, "up \(p.uptime)", human(bytes: Int64(size))].filter { !$0.isEmpty }.joined(separator: " · "),
                        tags: tags, help: idleHelp(p)) { hovering in
                    ProcessAction(p: p, s: s, visible: hovering)
                }
            }
            ForEach(others) { p in
                ItemRow(title: p.cwd.isEmpty ? p.name : p.cwd.split(separator: "/").suffix(2).joined(separator: "/"),
                        subtitle: "\(Self.kindName[p.kind] ?? p.kind) · up \(p.uptime) · \(human(bytes: Int64(p.rssBytes)))",
                        tags: p.stale ? ["stale"] : [], help: "pid \(p.pid) · \(Paths.abbreviate(p.cwd))") { hovering in
                    ProcessAction(p: p, s: s, visible: hovering)
                }
            }
            MCPCleanupNote(s: s, mcp: mcp)
        }
    }

    func idleHelp(_ p: DevProc) -> String {
        var lines = ["pid \(p.pid)"]
        if let since = p.idleSince {
            lines.append(p.idleTag == nil ? "Used in the last hour"
                         : "No tool calls since \(since.formatted(date: .omitted, time: .shortened))")
        }
        return lines.joined(separator: "\n")
    }
}

/// Stop for an MCP server (with its language server), Kill for anything else.
struct ProcessAction: View {
    @EnvironmentObject var m: Monitor
    let p: DevProc
    let s: Snapshot
    var visible = true

    var body: some View {
        if p.kind == "mcp" {
            let kids = s.procs.filter { $0.ppid == p.pid }
            HoverAction(key: "kill-\(p.pid)", icon: "xmark.circle", help: "Stop", visible: visible) {
                m.act("kill-\(p.pid)", confirm: .init(
                    title: "Stop this MCP server?",
                    message: "\(p.session ?? "The session that started it") loses those tools until it restarts.",
                    button: "Stop")) { Actions.kill(p, children: kids) }
            }
        } else {
            HoverAction(key: "kill-\(p.pid)", icon: "xmark.circle", help: "Kill", visible: visible) {
                m.act("kill-\(p.pid)") { Actions.kill(p) }
            }
        }
    }
}

/// Under the MCP rows: what the automatic cleanup is doing, and a way to do it now.
struct MCPCleanupNote: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot
    let mcp: [DevProc]

    var body: some View {
        let rule = s.config.processes.mcpCleanup
        let idle = MCPCleanup.candidates(s.procs, idleHours: rule.idleHours, keepNewest: rule.keepNewest)
        let freed = idle.reduce(UInt64(0)) { $0 + $1.bytes }
        VStack(alignment: .leading, spacing: 4) {
            if !mcp.isEmpty {
                Text(rule.enabled
                     ? "Auto-stop is on: idle \(hoursLabel(rule.idleHours))+, newest \(rule.keepNewest) kept. A stopped server's session loses its tools until that session restarts."
                     : "Turn on \"Stop idle MCP servers\" in the gear menu to stop servers idle \(hoursLabel(rule.idleHours))+ automatically.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !idle.isEmpty {
                Button("Stop \(idle.count) idle server\(idle.count == 1 ? "" : "s") now · frees \(human(bytes: Int64(freed)))") {
                    m.act("kill-idle-mcp", confirm: .init(
                        title: "Stop \(idle.count) idle MCP server\(idle.count == 1 ? "" : "s")?",
                        message: "Each has made no tool calls for \(hoursLabel(rule.idleHours)) or more. Their sessions lose those tools until they restart.",
                        button: "Stop")) {
                        let stopped = MCPCleanup.stop(idle, auto: false)
                        return MCPCleanup.summary(stopped)
                    }
                }
                .buttonStyle(.link).font(.caption)
            } else if mcp.count > 1 {
                let older = Array(mcp.sorted { $0.started < $1.started }.dropLast())
                let olderKids = s.procs.filter { p in older.contains { $0.pid == p.ppid } }
                let freed = (olderKids + older).reduce(UInt64(0)) { $0 + $1.rssBytes }
                Button("Stop all MCP servers but the newest · frees \(human(bytes: Int64(freed)))") {
                    m.act("kill-old-mcp", confirm: .init(
                        title: "Stop \(older.count) older MCP servers?",
                        message: "Their sessions lose those tools until they restart. The newest one is kept.",
                        button: "Stop")) { Actions.killAll(olderKids + older, action: "kill old MCP servers") }
                }
                .buttonStyle(.link).font(.caption)
            }
        }
        .padding(.top, 4)
    }
}

struct WorktreesFold: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot
    @State private var expanded: Set<String> = []

    static let shown = 5

    var body: some View {
        let total = s.worktrees.reduce(Int64(0)) { $0 + ($1.outputKB ?? 0) }
        let chore = s.worktrees.contains { $0.isChore(idleDays: s.config.worktrees.idleDays) }
        Fold("Worktrees", icon: "arrow.triangle.branch", value: "\(s.worktrees.count) · \(human(kb: total)) output",
             attention: chore) {
            ForEach(groups, id: \.self) { g in
                let units = s.worktrees.filter { $0.group == g }.sorted {
                    // sizes within 50 MB count as equal; then the one untouched longest first
                    let (x, y) = (($0.outputKB ?? -1) / 51200, ($1.outputKB ?? -1) / 51200)
                    return x != y ? x > y : $0.lastActivity < $1.lastActivity
                }
                let open = expanded.contains(g)
                HStack {
                    Caption(text: "\(g) · \(units.count)")
                    Spacer()
                    if units.count > Self.shown {
                        Button(open ? "Show fewer" : "Show all \(units.count)") {
                            if open { expanded.remove(g) } else { expanded.insert(g) }
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
                .padding(.top, 6)
                ForEach(open ? units : Array(units.prefix(Self.shown))) { WorktreeRow(u: $0) }
            }
            if s.worktrees.contains(where: \.hasClonableOutput) {
                Text("node_modules and vendor are often copy-on-write clones, which share disk with the original, so cleaning frees less than shown. The status line reports what was really freed.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            if m.measuringWorktrees {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Measuring build output…")
                }
                .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
    }

    var groups: [String] {
        var seen: [String] = []
        for u in s.worktrees where !seen.contains(u.group) { seen.append(u.group) }
        return seen
    }

    static func cleanConfirm(_ units: [WorktreeUnit]) -> Monitor.Confirm {
        var by: [String: Int64] = [:]
        for u in units { for b in u.breakdown { by[b.name, default: 0] += b.kb } }
        let kinds = by.sorted { $0.value > $1.value }.map { "\($0.key) \(human(kb: $0.value))" }.joined(separator: ", ")
        let what = units.count == 1 ? units[0].name : "\(units.count) merged worktrees"
        let names = units.count > 1 ? "\n\n" + units.prefix(12).map { "\($0.group)/\($0.name)" }.joined(separator: ", ")
            + (units.count > 12 ? " and \(units.count - 12) more" : "") : ""
        return .init(title: "Clean the build output of \(what)?",
                     message: "Deletes \(kinds.isEmpty ? "their regenerable folders" : kinds). They're git-ignored and come back on the next build or install. "
                        + (units.contains(where: \.hasClonableOutput) ? "Copy-on-write clones free less than du counts; Lapang reports what was really freed." : "")
                        + names,
                     button: "Clean")
    }
}

struct WorktreeRow: View {
    @EnvironmentObject var m: Monitor
    let u: WorktreeUnit

    var body: some View {
        let parts = u.breakdown.prefix(2).map { "\($0.name) \(human(kb: $0.kb))" }
        let size = u.outputs.isEmpty ? "no build output" : (parts.isEmpty ? "measuring…" : parts.joined(separator: " · "))
        ItemRow(title: u.name, subtitle: "\(size) · \(u.activityText)", tags: u.tags, help: help) { hovering in
            WorktreeAction(u: u, visible: hovering)
        }
        .onTapGesture { m.reveal(u.path) }
    }

    var help: String {
        var lines = [Paths.abbreviate(u.path)]
        for w in u.members {
            let name = u.members.count > 1 ? (w.path as NSString).lastPathComponent + ": " : ""
            lines.append(name + (w.branch ?? "detached") + (w.merged && !w.noCommits ? " (merged)" : ""))
        }
        lines.append("Click to reveal in Finder")
        return lines.joined(separator: "\n")
    }
}

struct WorktreeAction: View {
    @EnvironmentObject var m: Monitor
    let u: WorktreeUnit
    var visible = true

    var body: some View {
        HStack(spacing: 2) {
            if u.agentOpen {
                Image(systemName: "lock").foregroundStyle(.tertiary).frame(width: 22)
                    .help("A Claude Code session is working here")
            } else {
                if !u.outputs.isEmpty {
                    HoverAction(key: "wt-clean-" + u.path, icon: "eraser", help: "Clean build output", visible: visible) {
                        m.act("wt-clean-" + u.path, confirm: WorktreesFold.cleanConfirm([u])) { WorktreeActions.cleanOutput([u]) }
                    }
                } else {
                    Color.clear.frame(width: 22, height: 1)
                }
                HoverAction(key: "wt-rm-" + u.path, icon: "trash", help: "Remove worktree", visible: visible) {
                    m.act("wt-rm-" + u.path, check: { removeConfirm(u) }) { WorktreeActions.remove(u) }
                }
            }
        }
    }
}

/// Built off the main thread: it runs git status in each member.
private func removeConfirm(_ u: WorktreeUnit) -> Monitor.Confirm {
    let warnings = WorktreeActions.removalWarnings(u)
    let cmd = u.removeCommand.replacingOccurrences(of: "{repo}", with: u.repo.map(Paths.abbreviate) ?? "")
        .replacingOccurrences(of: "{path}", with: Paths.abbreviate(u.path))
        .replacingOccurrences(of: "{name}", with: u.name)
    return .init(title: "Remove the worktree \(u.name)?",
                 message: (warnings.isEmpty ? "" : warnings.joined(separator: " ") + "\n\n") + "Runs: \(cmd)",
                 button: "Remove")
}

struct PortsFold: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot

    var body: some View {
        let ls = s.ports
        let cfg = s.config.ports
        Fold("Ports", icon: "network", value: ls.isEmpty ? "None listening" : "\(ls.count) listening",
             attention: ls.contains(where: \.folderGone)) {
            if ls.isEmpty {
                Text("No servers of yours are listening").font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(ls) { l in
                ItemRow(title: l.title, subtitle: l.subtitle, tags: l.tags, help: l.help) { hovering in
                    PortAction(l: l, visible: hovering)
                }
            }
            Text(verbatim: "Your own servers on ports \(cfg.minPort)–\(cfg.maxPort), reachable only from this Mac unless tagged. App helpers and system services are left out.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }
    }
}

struct PortAction: View {
    @EnvironmentObject var m: Monitor
    let l: Listener
    var visible = true

    var body: some View {
        HStack(spacing: 2) {
            if let url = l.url {
                Button { m.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless).help("Open \(url)")
                    .opacity(visible ? 1 : 0).frame(width: 22)
            } else {
                Color.clear.frame(width: 22, height: 1)
            }
            if l.stoppable {
                HoverAction(key: "port-\(l.pid)", icon: "stop.circle", help: "Stop", visible: visible) {
                    m.act("port-\(l.pid)", confirm: PortActions.confirm(l)) { PortActions.stop(l) }
                }
            } else {
                Image(systemName: "lock").foregroundStyle(.tertiary).frame(width: 22)
                    .help(l.stopNote ?? "")
            }
        }
    }
}

struct SimAction: View {
    @EnvironmentObject var m: Monitor
    let sim: Sim
    var visible = true

    var body: some View {
        if sim.usage.building {
            Image(systemName: "lock").foregroundStyle(.tertiary).frame(width: 22)
                .help("Building; shutting it down now would break the build")
        } else {
            HoverAction(key: "sim-\(sim.udid)", icon: "power", help: "Shut down", visible: visible) {
                m.act("sim-\(sim.udid)") { Actions.shutdownSim(sim) }
            }
        }
    }
}

struct MemoryUsersFold: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot

    var body: some View {
        let top = s.memUsers.first
        Fold("Memory users", icon: "memorychip",
             value: top.map { "\($0.name) \(human(bytes: Int64($0.bytes)))" } ?? "",
             attention: s.pressureLevel != .ok) {
            ForEach(s.memUsers) { u in
                let subtitle = "\(human(bytes: Int64(u.bytes))) · \(u.processes) process\(u.processes == 1 ? "" : "es")"
                ItemRow(title: u.name, subtitle: subtitle, help: u.bundlePath.map(Paths.abbreviate)) { hovering in
                    MemoryUserAction(u: u, s: s, visible: hovering)
                }
            }
            Text("Memory footprint, as in Activity Monitor. Apps include their helper processes.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }
    }
}

/// Quit for an app, Shut down for the simulators.
struct MemoryUserAction: View {
    @EnvironmentObject var m: Monitor
    let u: MemoryUser
    let s: Snapshot
    var visible = true

    var body: some View {
        switch u.kind {
        case .simulators where !(s.sims ?? []).contains(where: { !$0.usage.building }):
            let sims = s.sims ?? []
            HoverAction(key: "mem-sims", icon: "power",
                        help: sims.buildingNote.map { "Shut down the others. \($0)" } ?? "Shut down all simulators", visible: visible) {
                m.act("mem-sims") { Actions.shutdownAllSims(sims) }
            }
        case .simulators where !(s.sims ?? []).isEmpty:
            Image(systemName: "lock").foregroundStyle(.tertiary).frame(width: 22)
                .help((s.sims ?? []).buildingNote ?? "")
        case .app where u.bundlePath.map(MemoryActions.isQuittable) == true:
            let bundle = u.bundlePath!
            HoverAction(key: "quit-\(u.name)", icon: "xmark.circle", help: "Quit \(u.name)", visible: visible) {
                m.act("quit-\(u.name)", confirm: .init(
                    title: "Quit \(u.name)?",
                    message: "Frees about \(human(bytes: Int64(u.bytes))). It quits like choosing Quit from its menu, so it can still ask to save.",
                    button: "Quit")) { MemoryActions.quit(bundlePath: bundle) }
            }
        default:
            Color.clear.frame(width: 22, height: 1)
        }
    }
}

// MARK: - Custom sections

struct CustomFold: View {
    let state: SectionState

    var body: some View {
        let cfg = state.config
        let badge = state.output?.badge
        Fold(cfg.title, icon: cfg.icon ?? "square.grid.2x2", value: state.error != nil ? "Error" : (badge?.text ?? ""),
             attention: state.error != nil || badge?.tone == "warn" || badge?.tone == "bad") {
            if let e = state.error {
                Text(e).font(.caption).foregroundStyle(.orange).padding(.vertical, 4)
            }
            if let out = state.output {
                ForEach(out.rows.filter { $0.group == nil }) { CustomRow(cfg: cfg, row: $0) }
                ForEach(groups(out.rows), id: \.self) { g in
                    let rows = out.rows.filter { $0.group == g }
                    DisclosureGroup("\(g) (\(rows.count))") {
                        ForEach(rows) { CustomRow(cfg: cfg, row: $0) }
                    }
                    .font(.callout)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    func groups(_ rows: [SectionRow]) -> [String] {
        var seen: [String] = []
        for r in rows { if let g = r.group, !seen.contains(g) { seen.append(g) } }
        return seen
    }
}

struct CustomRow: View {
    @EnvironmentObject var m: Monitor
    let cfg: SectionConfig
    let row: SectionRow

    var body: some View {
        let key = "section-\(cfg.id)-\(row.id)"
        let tags = (row.tags ?? []).map(\.text)
        ItemRow(title: row.title, subtitle: row.subtitle, tags: tags,
                help: row.reveal.map { "Click to reveal \($0) in Finder" }) { hovering in
            HStack(spacing: 6) {
                if let link = row.link {
                    Button { m.open(link) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.borderless).help("Open \(link)")
                        .opacity(hovering ? 1 : 0)
                }
                if m.running.contains(key) {
                    ProgressView().controlSize(.small).frame(width: 84)
                } else if let b = row.button {
                    Button { perform(key, b.title, b.run, b.confirm) } label: { Text(b.title).frame(maxWidth: .infinity) }
                        .controlSize(.small).frame(width: 84)
                } else if let menu = row.menu {
                    Menu {
                        ForEach(menu.items) { item in
                            Button((item.checked == true ? "✓ " : "") + item.title) {
                                perform(key, item.title, item.run, item.confirm)
                            }
                        }
                    } label: { Text(menu.title) }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .frame(width: 84, alignment: .trailing)
                }
            }
        }
        .onTapGesture { if let path = row.reveal { m.reveal(path) } }
    }

    func perform(_ key: String, _ title: String, _ args: [String], _ confirm: String?) {
        let cfg = self.cfg
        m.act(key, confirm: confirm.map { .init(title: "\(row.title): \(title)?", message: $0, button: "Continue") }) {
            Sections.perform(cfg, args, label: "\(row.title) · \(title)")
        }
    }
}

extension SimUsage {
    var tags: [String] { (building ? ["building"] : []) + (projectGone ? ["project gone"] : []) }

    /// "m4-review/carer-app-v2": the last two folders, which tell worktrees apart.
    var projectShort: String? { project.map { $0.split(separator: "/").suffix(2).joined(separator: "/") } }

    /// One line for the row: app · project · launcher, or "Building project · 4 min · via launcher".
    var summary: String? {
        var parts: [String] = []
        if building {
            parts.append("Building " + (projectShort ?? tool ?? "an app"))
            if let since { parts.append(durationText(since)) }
        } else {
            if !apps.isEmpty { parts.append(apps.map(\.name).joined(separator: ", ")) }
            if let p = projectShort { parts.append(p) }
        }
        if let l = launcher { parts.append("via " + l) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The full story, for the hover tooltip.
    var detail: String {
        var lines: [String] = []
        if building { lines.append("A build or install is running for it; shutting it down would break that.") }
        for a in apps { lines.append("\(a.name) (\(a.bundleID))") }
        if let p = project {
            lines.append("\(tool ?? "Started") in \(Paths.abbreviate(p))\(projectGone ? " (folder deleted)" : "")"
                + (since.map { " · \(durationText($0))" } ?? ""))
        }
        if let l = launcher { lines.append("Launched from \(l)") }
        return lines.isEmpty ? "No app of yours is running here" : lines.joined(separator: "\n")
    }
}

/// Time since a process started: "under a minute", "4 min", "1 h 20 min", "5 h", "3 d".
func durationText(_ since: Date) -> String {
    let s = Int(Date().timeIntervalSince(since))
    if s < 60 { return "under a minute" }
    if s < 3600 { return "\(s / 60) min" }
    if s < 3 * 3600 { return s % 3600 < 60 ? "\(s / 3600) h" : "\(s / 3600) h \(s % 3600 / 60) min" }
    if s < 86400 { return "\(s / 3600) h" }
    return "\(s / 86400) d"
}

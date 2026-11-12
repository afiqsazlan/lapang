import Charts
import SwiftUI

// MARK: - Building blocks

extension Level {
    var color: Color {
        switch self {
        case .ok: return .green
        case .warn: return .orange
        case .crit: return .red
        }
    }
}

func toneColor(_ tone: String?) -> Color {
    switch tone {
    case "good": return .green
    case "warn": return .orange
    case "bad": return .red
    case "info": return .blue
    default: return .secondary
    }
}

/// A collapsible card; open/closed is remembered per title.
struct Box<Trailing: View, Content: View>: View {
    let title: String
    let icon: String
    let trailing: Trailing
    let content: Content
    @AppStorage private var open: Bool

    init(_ title: String, icon: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.trailing = trailing()
        self.content = content()
        _open = AppStorage(wrappedValue: true, "open." + title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { open.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .foregroundStyle(.tertiary)
                        Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
                        Text(title).font(.headline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                trailing
            }
            if open { content }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
    }
}

struct Bar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color.gradient).frame(width: max(6, g.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 8)
    }
}

struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}

/// Icon button that becomes a spinner while its action runs.
struct ActionIcon: View {
    @EnvironmentObject var m: Monitor
    let key: String
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Group {
            if m.running.contains(key) {
                ProgressView().controlSize(.small)
            } else {
                Button(action: action) { Image(systemName: icon) }
                    .buttonStyle(.borderless)
                    .help(help)
            }
        }
        .frame(width: 22)
    }
}

struct ActionButton: View {
    @EnvironmentObject var m: Monitor
    let key: String
    let title: String
    let action: () -> Void

    var body: some View {
        if m.running.contains(key) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(title).foregroundStyle(.secondary)
            }
            .font(.callout)
        } else {
            Button(title, action: action).controlSize(.small)
        }
    }
}

struct Row<Trailing: View>: View {
    let icon: String
    var iconColor: Color = .secondary
    let title: String
    var subtitle: String? = nil
    var tags: [(String, Color)] = []
    var help: String? = nil
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(iconColor).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                    ForEach(tags.indices, id: \.self) { i in Tag(text: tags[i].0, color: tags[i].1) }
                }
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .help(help ?? "")
            Spacer(minLength: 4)
            trailing()
        }
    }
}

struct Caption: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

// MARK: - Disk & memory

struct DiskBox: View {
    let s: Snapshot
    @AppStorage("chartDays") private var days = 1

    var body: some View {
        Box("Disk", icon: "internaldrive") {
            switch s.diskLevel {
            case .ok: s.forecastWarning ? Tag(text: "Filling fast", color: .orange) : Tag(text: "OK", color: .green)
            case .warn: Tag(text: "Clean up soon", color: .orange)
            case .crit: Tag(text: "Almost full", color: .red)
            }
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.0f GB", s.freeGB))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(s.diskLevel == .ok ? Color.primary : s.diskLevel.color)
                Text(String(format: "free of %.0f GB", s.totalGB)).foregroundStyle(.secondary)
            }
            Bar(value: s.usedFraction, color: s.diskLevel.color)
            TrendLine(s: s)
            let shown = s.history.filter { Date().timeIntervalSince($0.t) <= Double(days) * 86400 }
            if shown.count >= 2 {
                HStack {
                    Caption(text: "Free space")
                    Spacer()
                    Picker("", selection: $days) {
                        Text("24h").tag(1)
                        Text("7d").tag(7)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 90)
                }
                HistoryChart(points: shown, warn: s.config.disk.warnGB, days: days,
                             forecast: days == 1 ? s.trend : nil, freeGB: s.freeGB)
            } else {
                Text("A chart of free space fills in here, one point every 5 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            GrowthList(s: s)
        }
    }
}

struct TrendLine: View {
    let s: Snapshot

    var body: some View {
        let t = s.trend
        let (icon, color, text): (String, Color, String) = {
            switch t.state {
            case .learning:
                let mins = Int(t.span / 60)
                return ("hourglass", .secondary,
                        "Learning the fill rate (\(mins < 60 ? "\(mins) min" : "\(mins / 60) h") of data, needs 2 h)")
            case .steady:
                return ("equal.circle", .secondary, "Steady, no real change")
            case .freeing:
                return ("arrow.up.right.circle", .green, String(format: "Freeing up %.1f GB/day", t.ratePerDay))
            case .filling:
                var line = String(format: "Filling %.1f GB/day", -t.ratePerDay)
                if let h = t.hoursToWarn, h > 0 {
                    line += " · \(Int(s.config.disk.warnGB)) GB left in \(durationText(hours: h))"
                } else if let h = t.hoursToFull {
                    line += " · full in \(durationText(hours: h))"
                }
                return ("arrow.down.right.circle", s.forecastWarning || s.diskLevel != .ok ? .orange : .secondary, line)
            }
        }()
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).foregroundStyle(color == .secondary ? Color.secondary : color)
            Spacer()
            if t.sinceCleanup && t.state != .learning {
                Text("since last cleanup").foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .help("A straight-line fit over the last 24 hours of free space, restarting after a cleanup.")
    }
}

struct GrowthList: View {
    let s: Snapshot

    var body: some View {
        if let g = s.growth {
            VStack(alignment: .leading, spacing: 4) {
                Caption(text: "Change since \(g.since.formatted(.relative(presentation: .named)))")
                    .padding(.top, 4)
                if g.items.isEmpty {
                    Text("No measured folder changed by more than 50 MB.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(g.items) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text((i.deltaKB > 0 ? "+" : "−") + human(kb: abs(i.deltaKB)))
                            .monospacedDigit()
                            .foregroundStyle(i.deltaKB > 0 ? Color.orange : Color.green)
                            .frame(width: 64, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(i.name)
                            if let d = i.detail {
                                Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    .font(.caption)
                }
                if let u = g.untrackedKB, abs(u) >= 500 * 1024 {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text((u > 0 ? "+" : "−") + human(kb: abs(u)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                        Text("Everything else (simulators, app data, downloads…)").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        } else if s.sizesMeasuredAt != nil {
            Text("What's growing shows up after a second size check, about 30 minutes from the first.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct HistoryChart: View {
    let points: [HistoryPoint]
    let warn: Double
    let days: Int
    let forecast: Trend?
    let freeGB: Double

    var body: some View {
        // dashed projection up to 6 hours ahead while the disk is filling
        let projection: [HistoryPoint] = {
            guard let f = forecast, f.state == .filling, let last = points.last else { return [] }
            let hours = min(6, f.hoursToFull ?? 6)
            let end = last.t.addingTimeInterval(hours * 3600)
            return [last, HistoryPoint(t: end, freeGB: max(0, last.freeGB + f.ratePerDay / 24 * hours))]
        }()
        let top = max(points.map(\.freeGB).max() ?? 0, warn) * 1.25
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Time", p.t), y: .value("Free GB", p.freeGB))
                    .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.25), .accentColor.opacity(0.02)],
                                                     startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", p.t), y: .value("Free GB", p.freeGB), series: .value("Series", "free"))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            ForEach(projection) { p in
                LineMark(x: .value("Time", p.t), y: .value("Free GB", p.freeGB), series: .value("Series", "forecast"))
                    .foregroundStyle(Color.orange.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            RuleMark(y: .value("Warn", warn))
                .foregroundStyle(.orange.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .annotation(position: .top, alignment: .leading) {
                    Text("\(Int(warn)) GB").font(.caption2).foregroundStyle(.orange)
                }
        }
        .chartYScale(domain: 0 ... top)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: days == 1 ? 4 : 7)) { _ in
                if days == 1 {
                    AxisValueLabel(format: .dateTime.hour())
                } else {
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
        .frame(height: 90)
    }
}

struct MemoryBox: View {
    let s: Snapshot

    var body: some View {
        Box("Memory", icon: "memorychip") {
            switch s.pressureLevel {
            case .ok: Tag(text: "Normal", color: .green)
            case .warn: Tag(text: "Pressure", color: .orange)
            case .crit: Tag(text: "Critical", color: .red)
            }
        } content: {
            HStack {
                Text("Swap").foregroundStyle(.secondary)
                Spacer()
                Text("\(human(bytes: Int64(s.swapUsed))) of \(human(bytes: Int64(s.swapTotal)))").monospacedDigit()
            }
            .font(.callout)
            Bar(value: s.swapFraction, color: s.swapFraction > 0.8 ? .orange : .accentColor)
            if s.swapFraction > 0.8 && s.diskLevel != .ok {
                Text("Swap is nearly full and can't grow on a nearly full disk. Freeing disk space helps memory too.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Simulators

struct SimBox: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot

    var body: some View {
        let sims = s.sims ?? []
        Box("Simulators", icon: "iphone") {
            if !sims.isEmpty {
                ActionButton(key: "sim-all", title: "Shut down all") {
                    m.act("sim-all") { Actions.shutdownAllSims() }
                }
            }
        } content: {
            if sims.isEmpty {
                Text("None booted").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(sims) { sim in
                Row(icon: "iphone", iconColor: .green, title: sim.name) {
                    ActionIcon(key: "sim-\(sim.udid)", icon: "power", help: "Shut down") {
                        let udid = sim.udid
                        m.act("sim-\(udid)") { Actions.shutdownSim(udid) }
                    }
                }
            }
        }
    }
}

// MARK: - Dev processes

struct ProcessBox: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot

    static let kindName = [
        "mcp": "MCP server", "lsp": "language server", "devtools": "DevTools service",
        "compiler": "compiler", "flutter": "flutter run",
    ]

    var body: some View {
        let mcp = s.procs.filter { $0.kind == "mcp" }
        let mcpPids = Set(mcp.map(\.pid))
        // language servers started by an MCP server are shown as part of it
        let others = s.procs.filter { $0.kind != "mcp" && !mcpPids.contains($0.ppid) }
        let stale = s.procs.filter(\.stale)
        let total = s.procs.reduce(UInt64(0)) { $0 + $1.rssBytes }

        Box("Dev processes", icon: "cpu") {
            HStack(spacing: 8) {
                Text("\(s.procs.count) · \(human(bytes: Int64(total)))").font(.caption).foregroundStyle(.secondary)
                if !stale.isEmpty {
                    ActionButton(key: "kill-stale", title: "Kill \(stale.count) stale") {
                        m.act("kill-stale") { Actions.killAll(stale) }
                    }
                }
            }
        } content: {
            if s.procs.isEmpty {
                Text("None running (\(s.config.processes.names.joined(separator: ", ")))")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !mcp.isEmpty {
                Caption(text: "MCP servers")
                ForEach(mcp) { p in
                    let kids = s.procs.filter { $0.ppid == p.pid }
                    let size = p.rssBytes + kids.reduce(0) { $0 + $1.rssBytes }
                    Row(icon: "sparkles", title: kids.isEmpty ? "\(p.name) MCP server" : "\(p.name) MCP + language server",
                        subtitle: "pid \(p.pid) · up \(p.uptime) · \(human(bytes: Int64(size)))",
                        tags: p.stale ? [("STALE", .orange)] : []) {
                        ActionIcon(key: "kill-\(p.pid)", icon: "xmark.circle", help: "Kill") {
                            m.act("kill-\(p.pid)", confirm: .init(
                                title: "Kill this MCP server?",
                                message: "The app or agent session that started it loses those tools until it restarts.",
                                button: "Kill")) { Actions.kill(p, children: kids) }
                        }
                    }
                }
                if mcp.count > 1 {
                    let older = Array(mcp.dropLast())
                    let olderKids = s.procs.filter { p in older.contains { $0.pid == p.ppid } }
                    ActionButton(key: "kill-old-mcp", title: "Kill all but the newest") {
                        m.act("kill-old-mcp", confirm: .init(
                            title: "Kill \(older.count) older MCP servers?",
                            message: "Their sessions lose those tools until they restart. The newest one is kept.",
                            button: "Kill")) { Actions.killAll(olderKids + older) }
                    }
                }
            }
            if !others.isEmpty {
                if !mcp.isEmpty { Caption(text: "Other").padding(.top, 2) }
                ForEach(others) { p in
                    Row(icon: "bolt.horizontal",
                        title: p.cwd.isEmpty ? p.name : p.cwd.split(separator: "/").suffix(2).joined(separator: "/"),
                        subtitle: "\(Self.kindName[p.kind] ?? p.kind) · up \(p.uptime) · \(human(bytes: Int64(p.rssBytes)))",
                        tags: p.stale ? [("STALE", .orange)] : [],
                        help: "pid \(p.pid) · \(Paths.abbreviate(p.cwd))") {
                        ActionIcon(key: "kill-\(p.pid)", icon: "xmark.circle", help: "Kill") {
                            m.act("kill-\(p.pid)") { Actions.kill(p) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Xcode build caches

struct XcodeBox: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot

    var body: some View {
        let idleDays = s.config.xcode.idleDays
        let orphans = s.derived.filter { $0.status == .orphan }
        let unused = s.derived.filter { $0.status == .orphan || ($0.status == .live && $0.idleDays >= idleDays) }
        let sum: ([DerivedEntry]) -> Int64 = { $0.reduce(0) { $0 + ($1.sizeKB ?? 0) } }
        let root = s.derivedDataRoot

        Box("Xcode build caches", icon: "hammer") {
            Text(human(kb: s.derivedTotalKB)).font(.caption).foregroundStyle(.secondary)
        } content: {
            ForEach(s.derived.sorted { ($0.sizeKB ?? 0) > ($1.sizeKB ?? 0) }) { e in
                DerivedRow(e: e, idleDays: idleDays, root: root)
            }
            if !orphans.isEmpty || unused.count > orphans.count {
                HStack(spacing: 8) {
                    if !orphans.isEmpty {
                        ActionButton(key: "dd-orphan", title: "Clean orphaned · \(human(kb: sum(orphans)))") {
                            m.act("dd-orphan", confirm: .init(
                                title: "Delete \(orphans.count) orphaned build caches?",
                                message: "Their projects are gone. About \(human(kb: sum(orphans))). Protected projects are never touched.",
                                button: "Delete")) { Actions.deleteDerived(orphans, root: root) }
                        }
                    }
                    if unused.count > orphans.count {
                        ActionButton(key: "dd-unused", title: "Clean unused \(idleDays)d+ · \(human(kb: sum(unused)))") {
                            m.act("dd-unused", confirm: .init(
                                title: "Delete \(unused.count) build caches?",
                                message: "Orphaned ones plus projects not built for \(idleDays)+ days, about \(human(kb: sum(unused))). Their next build starts from scratch. Protected projects are never touched.",
                                button: "Delete")) { Actions.deleteDerived(unused, root: root) }
                        }
                    }
                }
                .padding(.top, 2)
            }
            SizesNote(s: s)
        }
    }
}

struct DerivedRow: View {
    @EnvironmentObject var m: Monitor
    let e: DerivedEntry
    let idleDays: Int
    let root: String

    var body: some View {
        let age = e.idleDays == 0 ? "built today" : "built \(e.idleDays)d ago"
        let (icon, color, tags): (String, Color, [(String, Color)]) = {
            switch e.status {
            case .protected: return ("lock.fill", .secondary, [("protected", .blue)])
            case .orphan: return ("trash", .orange, [("project gone", .orange)])
            case .new: return ("hourglass", .secondary, [("building", .secondary)])
            case .live: return ("folder", .secondary, e.idleDays >= idleDays ? [("unused", .secondary)] : [])
            }
        }()
        Row(icon: icon, iconColor: color, title: e.title, subtitle: "\(human(kb: e.sizeKB)) · \(age)", tags: tags,
            help: e.projectDir.map(Paths.abbreviate) ?? e.name) {
            ActionIcon(key: "dd-\(e.name)", icon: "trash", help: "Delete this build cache") {
                let extra = e.status == .protected ? " This project is protected: its next build starts from scratch." : ""
                m.act("dd-\(e.name)", confirm: .init(
                    title: "Delete the build cache for \(e.title)?",
                    message: "\(human(kb: e.sizeKB)).\(extra)", button: "Delete")) { Actions.deleteDerived([e], root: root) }
            }
        }
    }
}

struct SizesNote: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot

    var body: some View {
        HStack {
            if m.measuring {
                ProgressView().controlSize(.mini)
                Text("Measuring folder sizes…").font(.caption).foregroundStyle(.secondary)
            } else if let t = s.sizesMeasuredAt {
                Text("Sizes measured \(t.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - Package caches

struct CachesBox: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot

    var body: some View {
        let total = s.caches.reduce(Int64(0)) { $0 + ($1.sizeKB ?? 0) }
        Box("Package caches", icon: "shippingbox") {
            Text(human(kb: total)).font(.caption).foregroundStyle(.secondary)
        } content: {
            ForEach(s.caches.sorted { ($0.sizeKB ?? 0) > ($1.sizeKB ?? 0) }) { c in
                Row(icon: "shippingbox", title: c.name,
                    subtitle: human(kb: c.sizeKB) + (c.note.map { " · " + $0 } ?? ""),
                    help: Paths.abbreviate(c.path)) {
                    if c.clearable {
                        ActionButton(key: "cache-\(c.id)", title: "Clear") {
                            m.act("cache-\(c.id)", confirm: .init(
                                title: "Clear the \(c.name) cache?",
                                message: "\(human(kb: c.sizeKB)) in \(Paths.abbreviate(c.path)). It refills on the next install.",
                                button: "Clear")) { Actions.clearCache(c) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Custom sections

struct CustomBox: View {
    @EnvironmentObject var m: Monitor
    let state: SectionState

    var body: some View {
        let cfg = state.config
        Box(cfg.title, icon: cfg.icon ?? "square.grid.2x2") {
            if let b = state.output?.badge { Tag(text: b.text, color: toneColor(b.tone)) }
        } content: {
            if let e = state.error {
                Text(e).font(.caption).foregroundStyle(.orange)
            }
            if let out = state.output {
                ForEach(out.rows.filter { $0.group == nil }) { CustomRow(cfg: cfg, row: $0) }
                ForEach(groups(out.rows), id: \.self) { g in
                    let rows = out.rows.filter { $0.group == g }
                    DisclosureGroup("\(g) (\(rows.count))") {
                        ForEach(rows) { CustomRow(cfg: cfg, row: $0) }
                    }
                    .font(.callout)
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
        let tags = (row.tags ?? []).map { ($0.text, toneColor($0.tone)) }
        HStack(spacing: 4) {
            if let path = row.reveal {
                Button { m.reveal(path) } label: {
                    Row(icon: row.icon ?? "circle.fill", title: row.title, subtitle: row.subtitle, tags: tags,
                        help: "Reveal \(path) in Finder") { EmptyView() }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Row(icon: row.icon ?? "circle.fill", title: row.title, subtitle: row.subtitle, tags: tags) { EmptyView() }
            }
            if let link = row.link {
                Button { m.open(link) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless).help("Open \(link)")
            }
            if m.running.contains(key) {
                ProgressView().controlSize(.small)
            } else {
                if let b = row.button {
                    Button(b.title) { perform(key, b.title, b.run, b.confirm) }.controlSize(.small)
                }
                if let menu = row.menu {
                    Menu(menu.title) {
                        ForEach(menu.items) { item in
                            Button((item.checked == true ? "✓ " : "") + item.title) {
                                perform(key, item.title, item.run, item.confirm)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
    }

    func perform(_ key: String, _ title: String, _ args: [String], _ confirm: String?) {
        let cfg = self.cfg
        m.act(key, confirm: confirm.map { .init(title: "\(row.title): \(title)?", message: $0, button: "Continue") }) {
            Sections.perform(cfg, args)
        }
    }
}

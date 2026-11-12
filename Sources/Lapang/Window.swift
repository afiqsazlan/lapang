import Charts
import SwiftUI

// The Lapang window: a sidebar with one page per section of the panel, an overview of disk,
// memory and what to clean, sortable tables, and the action log as a timeline. Everything comes
// from the same snapshot and uses the same row actions as the panel; only the layout is new.

// MARK: - Pages

struct WindowPage: Identifiable {
    enum Group: String, CaseIterable {
        case main = "", dev = "Dev", caches = "Caches", custom = "Custom", footer = " "
    }

    let id: String
    let title: String
    let icon: String
    let group: Group
    var value = ""
    var attention = false
    var subtitle: String? = nil
    /// Pages built around a table fill the window and let the table scroll.
    var scrolls = true
    let content: () -> AnyView
}

extension Snapshot {
    /// The sidebar, in order. A section shows up here when the snapshot has it, the same rule the
    /// panel uses. A new section gets a page here; until it has a table of its own, its fold can
    /// stand in with `.environment(\.foldAsPage, true)` (custom sections do that).
    var windowPages: [WindowPage] {
        let chores = self.chores
        let memShare = memTotal > 0 ? Int((Double(memUsed) / Double(memTotal) * 100).rounded()) : 0
        var pages: [WindowPage] = [
            .init(id: "overview", title: "Overview", icon: "square.grid.2x2", group: .main,
                  value: chores.isEmpty ? "" : "\(chores.count)", attention: !chores.isEmpty,
                  subtitle: chores.isEmpty ? "Nothing to clean" : nil) { AnyView(OverviewPage(s: self)) },
            .init(id: "disk", title: "Disk", icon: "internaldrive", group: .main,
                  value: String(format: "%.0f GB free", freeGB), attention: diskLevel != .ok || forecastWarning,
                  subtitle: String(format: "%.0f GB free of %.0f GB", freeGB, totalGB)) { AnyView(DiskPage(s: self)) },
            .init(id: "memory", title: "Memory", icon: "memorychip", group: .main,
                  value: "\(memShare)%", attention: pressureLevel != .ok,
                  subtitle: String(format: "%.1f of %.0f GB used · %@", Double(memUsed) / 1_073_741_824,
                                   Double(memTotal) / 1_073_741_824, pressureText),
                  scrolls: false) { AnyView(MemoryPage(s: self)) },
        ]
        if !config.processes.names.isEmpty {
            let total = procs.reduce(UInt64(0)) { $0 + $1.rssBytes }
            pages.append(.init(id: "processes", title: "Processes", icon: "cpu", group: .dev,
                               value: "\(procs.count)", attention: procs.contains(where: \.stale),
                               subtitle: "\(procs.count) running · \(human(bytes: Int64(total)))",
                               scrolls: false) { AnyView(ProcessesPage(s: self)) })
        }
        if let sims {
            pages.append(.init(id: "simulators", title: "Simulators", icon: "iphone", group: .dev,
                               value: "\(sims.count)", attention: sims.contains { $0.usage.projectGone },
                               subtitle: sims.isEmpty ? "None booted" : "\(sims.count) running",
                               scrolls: false) { AnyView(SimulatorsPage(s: self)) })
        }
        if !worktrees.isEmpty {
            let total = worktrees.reduce(Int64(0)) { $0 + ($1.outputKB ?? 0) }
            pages.append(.init(id: "worktrees", title: "Worktrees", icon: "arrow.triangle.branch", group: .dev,
                               value: "\(worktrees.count)",
                               attention: worktrees.contains { $0.isChore(idleDays: config.worktrees.idleDays) },
                               subtitle: "\(worktrees.count) · \(human(kb: total)) of build output",
                               scrolls: false) { AnyView(WorktreesPage(s: self)) })
        }
        pages.append(.init(id: "ports", title: "Ports", icon: "network", group: .dev,
                           value: ports.isEmpty ? "" : "\(ports.count)", attention: ports.contains(where: \.folderGone),
                           subtitle: ports.isEmpty ? "None listening" : "\(ports.count) listening",
                           scrolls: false) { AnyView(PortsPage(s: self)) })
        if !derived.isEmpty {
            pages.append(.init(id: "xcode", title: "Xcode builds", icon: "hammer", group: .caches,
                               value: human(kb: derivedTotalKB),
                               attention: derived.contains { $0.status == .orphan },
                               subtitle: "\(human(kb: derivedTotalKB)) in \(derived.count) caches",
                               scrolls: false) { AnyView(XcodePage(s: self)) })
        }
        if !caches.isEmpty {
            let total = caches.reduce(Int64(0)) { $0 + ($1.sizeKB ?? 0) }
            pages.append(.init(id: "caches", title: "Package caches", icon: "shippingbox", group: .caches,
                               value: human(kb: total), subtitle: "\(human(kb: total)) in \(caches.count) caches",
                               scrolls: false) { AnyView(CachesPage(s: self)) })
        }
        for st in sections {
            let badge = st.output?.badge
            pages.append(.init(id: "section-" + st.id, title: st.config.title, icon: st.config.icon ?? "square.grid.2x2",
                               group: .custom, value: st.error != nil ? "Error" : (badge?.text ?? ""),
                               attention: st.error != nil || badge?.tone == "warn" || badge?.tone == "bad") {
                AnyView(CustomFold(state: st).environment(\.foldAsPage, true))
            })
        }
        let log = ActionLog.recent()
        let today = log.filter { Calendar.current.isDateInToday($0.time) }.count
        pages.append(.init(id: "activity", title: "Activity", icon: "clock", group: .footer,
                           value: today > 0 ? "\(today) today" : "", subtitle: ActivityPage.summary(log)) {
            AnyView(ActivityPage(entries: log))
        })
        return pages
    }

    var pressureText: String {
        switch pressureLevel {
        case .ok: return "Normal"
        case .warn: return "Under pressure"
        case .crit: return "Critical"
        }
    }
}

private struct OpenPageKey: EnvironmentKey { static let defaultValue: (String) -> Void = { _ in } }
extension EnvironmentValues {
    /// Switches the window to another page, for "All ›" links.
    var openPage: (String) -> Void {
        get { self[OpenPageKey.self] }
        set { self[OpenPageKey.self] = newValue }
    }
}

// MARK: - Window

struct MainWindow: View {
    static let defaultSize = CGSize(width: 1000, height: 700)
    static let minSize = CGSize(width: 780, height: 500)

    @EnvironmentObject var m: Monitor
    @State private var page: String

    init(page: String? = nil) {
        _page = State(initialValue: page ?? UserDefaults.standard.string(forKey: "window.page") ?? "overview")
    }

    var body: some View {
        Group {
            if let s = m.snap {
                content(s)
            } else {
                ProgressView("Looking around…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.openPage) { page = $0 }
        .onChange(of: page) { UserDefaults.standard.set($1, forKey: "window.page") }
        .onAppear { Task { await m.refresh() } }
    }

    func content(_ s: Snapshot) -> some View {
        let pages = s.windowPages
        let current = pages.first { $0.id == page } ?? pages[0]
        return HStack(spacing: 0) {
            Sidebar(pages: pages, selected: current.id) { page = $0 }
                .frame(width: 236)
            Divider()
            VStack(spacing: 0) {
                TopBar(page: current)
                Divider()
                if current.scrolls {
                    ScrollView {
                        current.content()
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    current.content()
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .ignoresSafeArea()  // the window has no title bar: the sidebar runs up behind the traffic lights
    }
}

private struct Sidebar: View {
    let pages: [WindowPage]
    let selected: String
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(WindowPage.Group.allCases.filter { $0 != .footer }, id: \.self) { g in
                        let items = pages.filter { $0.group == g }
                        if !items.isEmpty {
                            if g != .main {
                                Text(g.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                    .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 3)
                            }
                            ForEach(items) { row($0) }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            ForEach(pages.filter { $0.group == .footer }) { row($0) }
        }
        .padding(.horizontal, 10).padding(.top, 46).padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.045))
    }

    func row(_ p: WindowPage) -> some View {
        SidebarRow(page: p, selected: p.id == selected) { select(p.id) }
    }
}

private struct SidebarRow: View {
    let page: WindowPage
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: page.icon).foregroundStyle(.secondary).frame(width: 18)
                Text(page.title).lineLimit(1)
                Spacer(minLength: 6)
                if page.attention { Circle().fill(Color.orange).frame(width: 6, height: 6) }
                Text(page.value).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    .layoutPriority(-1)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(selected ? 0.08 : (hovering ? 0.04 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct TopBar: View {
    @EnvironmentObject var m: Monitor
    let page: WindowPage

    var body: some View {
        HStack(spacing: 12) {
            Text(page.title).font(.title3.weight(.semibold))
            if let sub = page.subtitle {
                Text(sub).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if let msg = m.message {
                Text(msg).lineLimit(1).truncationMode(.tail)
            } else if let u = m.updated {
                Text("Updated \(u.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
            }
            if m.refreshing || m.measuring { ProgressView().controlSize(.small) }
            Button { Task { await m.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh now (⌘R)")
            GearMenu()
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .frame(height: 52)
    }
}

// MARK: - Building blocks

extension View {
    /// A bordered card; cards in one row grow to the tallest.
    func card() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
    }
}

private struct CardTitle: View {
    @Environment(\.openPage) private var openPage
    let title: String
    var link: (text: String, page: String)? = nil

    var body: some View {
        HStack {
            Caption(text: title)
            Spacer()
            if let link {
                Button(link.text) { openPage(link.page) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct BigNumber: View {
    let value: String
    let unit: String
    var color: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(color)
            Text(unit).foregroundStyle(.secondary)
        }
    }
}

/// A row's trailing number, right-aligned in its column.
private struct Num: View {
    let text: String
    var body: some View {
        Text(text).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct Footnote: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Disk and memory

struct DiskCard: View {
    let s: Snapshot
    var chartHeight: CGFloat = 120
    @AppStorage("chartDays") private var days = 1

    var body: some View {
        let shown = s.history.filter { Date().timeIntervalSince($0.t) <= Double(days) * 86400 }
        let tint = s.diskLevel == .ok ? Color.primary : s.diskLevel.color
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Caption(text: "Disk")
                Spacer()
                Picker("", selection: $days) {
                    Text("24h").tag(1)
                    Text("7d").tag(7)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 90)
            }
            BigNumber(value: String(format: "%.0f GB", s.freeGB), unit: String(format: "free of %.0f GB", s.totalGB), color: tint)
            Bar(value: s.usedFraction, color: s.diskLevel == .ok ? Color.secondary : s.diskLevel.color)
            if shown.count >= 2 {
                HistoryChart(points: shown, warn: s.config.disk.warnGB, days: days,
                             forecast: days == 1 ? s.trend : nil, height: chartHeight)
                    .padding(.top, 4)
            } else {
                Footnote(text: "The chart fills in over the next hours.").frame(height: chartHeight)
            }
            TrendLine(s: s)
        }
    }
}

struct MemoryCard: View {
    let s: Snapshot
    var chartHeight: CGFloat = 54

    var body: some View {
        let line = MemoryLine(s: s)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Caption(text: "Memory")
                Spacer()
                if s.pressureLevel != .ok { Circle().fill(s.pressureLevel.color).frame(width: 6, height: 6) }
                Text(s.pressureText).font(.callout).foregroundStyle(s.pressureLevel.color)
            }
            BigNumber(value: String(format: "%.1f GB", Double(s.memUsed) / 1_073_741_824),
                      unit: String(format: "used of %.0f GB", Double(s.memTotal) / 1_073_741_824))
            HStack {
                Text("Pressure")
                Spacer()
                Text(line.historyText)
            }
            .font(.caption).foregroundStyle(.secondary)
            PressureStrip(points: s.memHistory, height: 14)
            HStack {
                Text("24 h ago")
                Spacer()
                Text("12 h ago")
                Spacer()
                Text("now")
            }
            .font(.caption2).foregroundStyle(.tertiary)
            HStack {
                Text("Swap")
                Spacer()
                Text("\(human(bytes: Int64(s.swapUsed))) of \(human(bytes: Int64(s.swapTotal)))").monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(s.swapFraction > 0.8 ? Color.orange : Color.secondary)
            .padding(.top, 2)
            MemoryChart(points: s.memHistory, value: \.swapGB, top: Double(s.swapTotal) / 1_073_741_824, height: chartHeight)
            if s.swapFraction > 0.8 && s.diskLevel != .ok {
                Text("Swap lives on the disk and can't grow while it's this full. Freeing disk space helps memory too.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .help("Memory pressure is how hard macOS is working to find RAM. Swap is RAM spilled onto the disk.")
    }
}

/// One memory figure over the last 24 hours, against its ceiling (RAM, or the swap file's size).
struct MemoryChart: View {
    let points: [MemoryPoint]
    let value: KeyPath<MemoryPoint, Double>
    let top: Double
    var height: CGFloat = 54

    var body: some View {
        // a point a minute is more than a chart this size can show
        let shown = points.enumerated().filter { $0.offset % 5 == 0 || $0.offset == points.count - 1 }.map(\.element)
        let high = max(top, shown.map { $0[keyPath: value] }.max() ?? 0, 1)
        let now = Date()
        Chart {
            ForEach(shown) { p in
                AreaMark(x: .value("Time", p.t), y: .value("GB", p[keyPath: value]))
                    .foregroundStyle(Color.secondary.opacity(0.12))
                LineMark(x: .value("Time", p.t), y: .value("GB", p[keyPath: value]))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.3))
            }
            if top > 0 {
                RuleMark(y: .value("Max", top))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }
        .chartXScale(domain: now.addingTimeInterval(-86400) ... now)
        .chartYScale(domain: 0 ... high * 1.08)
        .chartXAxis {
            AxisMarks(values: hourTicks(now.addingTimeInterval(-86400), now, every: 6)) { _ in
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, top]) { v in
                AxisGridLine()
                AxisValueLabel { if let g = v.as(Double.self) { Text("\(Int(g.rounded()))G") } }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Overview

struct OverviewPage: View {
    let s: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let e = s.configError {
                Text(e).font(.caption).foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 14) {
                DiskCard(s: s).card()
                MemoryCard(s: s).card()
            }
            .fixedSize(horizontal: false, vertical: true)
            ChoresBlock(s: s, wide: true)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    CardTitle(title: "Memory users", link: ("All \(s.memUsers.count) ›", "memory"))
                    TopMemoryUsers(users: Array(s.memUsers.prefix(5)))
                }
                .card()
                VStack(alignment: .leading, spacing: 6) {
                    CardTitle(title: "Recent actions", link: ("Activity ›", "activity"))
                    let groups = ActivityPage.grouped(ActionLog.recent(40))
                    if groups.isEmpty {
                        Footnote(text: "Nothing yet. What you clean, kill or shut down shows up here.")
                    }
                    ForEach(groups.prefix(4)) { ActionRow(group: $0, showSource: false, nested: false) }
                }
                .card()
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TopMemoryUsers: View {
    let users: [MemoryUser]

    var body: some View {
        let top = Double(users.first?.bytes ?? 1)
        VStack(spacing: 6) {
            ForEach(users) { u in
                HStack(spacing: 10) {
                    Text(u.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Bar(value: Double(u.bytes) / top, color: Color.secondary.opacity(0.7), height: 5).frame(width: 140)
                    Text(human(bytes: Int64(u.bytes))).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
                .font(.callout)
            }
        }
    }
}

// MARK: - Disk page

struct DiskPage: View {
    let s: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DiskCard(s: s, chartHeight: 220).card()
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Caption(text: "Measured folders")
                    MeasuredFolders(s: s)
                    SizesNote(s: s)
                }
                .card()
                VStack(alignment: .leading, spacing: 6) {
                    GrowthList(s: s)
                    if s.growth == nil && s.sizesMeasuredAt == nil {
                        Footnote(text: "What grew shows up after two size checks.")
                    }
                }
                .card()
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What Lapang measures, as a share of the used disk; each line opens its page.
private struct MeasuredFolders: View {
    @Environment(\.openPage) private var openPage
    let s: Snapshot

    var body: some View {
        let rows: [(String, Int64, String)] = [
            ("Xcode build caches", s.derivedTotalKB ?? 0, "xcode"),
            ("Package caches", s.caches.reduce(Int64(0)) { $0 + ($1.sizeKB ?? 0) }, "caches"),
            ("Worktree build output", s.worktrees.reduce(Int64(0)) { $0 + ($1.outputKB ?? 0) }, "worktrees"),
        ].filter { $0.1 > 0 }
        let top = Double(rows.map(\.1).max() ?? 1)
        VStack(spacing: 6) {
            ForEach(rows, id: \.0) { r in
                Button { openPage(r.2) } label: {
                    HStack(spacing: 10) {
                        Text(r.0).frame(maxWidth: .infinity, alignment: .leading)
                        Bar(value: Double(r.1) / top, color: Color.secondary.opacity(0.7), height: 5)
                            .frame(width: 120)
                        Text(human(kb: r.1)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if rows.isEmpty { Footnote(text: "Sizes come in after the first measurement.") }
        }
        .font(.callout)
    }
}

// MARK: - Memory page

struct MemoryPage: View {
    let s: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                MemoryCard(s: s).card()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Caption(text: "RAM used, last 24 h")
                        Spacer()
                        Text(String(format: "%.1f of %.0f GB", Double(s.memUsed) / 1_073_741_824,
                                    Double(s.memTotal) / 1_073_741_824))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    MemoryChart(points: s.memHistory, value: \.usedGB, top: Double(s.memTotal) / 1_073_741_824, height: 180)
                }
                .card()
            }
            .fixedSize(horizontal: false, vertical: true)
            MemoryUsersTable(s: s)
            Footnote(text: "Memory footprint, as in Activity Monitor. Apps include their helper processes.")
        }
    }
}

private struct MemoryUsersTable: View {
    let s: Snapshot
    @State private var order = [KeyPathComparator(\MemoryUser.bytes, order: .reverse)]

    var body: some View {
        let top = Double(s.memUsers.map(\.bytes).max() ?? 1)
        Table(s.memUsers.sorted(using: order), sortOrder: $order) {
            TableColumn("App", value: \.name)
            TableColumn("Memory", value: \.bytes) { u in Num(text: human(bytes: Int64(u.bytes))) }
                .width(min: 70, ideal: 80, max: 100)
            TableColumn("Processes", value: \.processes) { u in Num(text: "\(u.processes)") }
                .width(min: 60, ideal: 70, max: 90)
            TableColumn("") { u in Bar(value: Double(u.bytes) / top, color: Color.secondary.opacity(0.6), height: 5) }
                .width(min: 60, ideal: 160)
            TableColumn("") { u in MemoryUserAction(u: u, s: s) }
                .width(28)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
    }
}

// MARK: - Dev

extension DevProc {
    var label: String {
        kind == "mcp" ? "\(name) MCP server" : (ProcessFold.kindName[kind] ?? kind)
    }

    var sessionText: String { stale && kind == "mcp" ? "session gone" : (session ?? "") }
}

struct ProcessesPage: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot
    @State private var order = [KeyPathComparator(\DevProc.rssBytes, order: .reverse)]
    @State private var selection = Set<pid_t>()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Table(s.procs.sorted(using: order), selection: $selection, sortOrder: $order) {
                TableColumn("Process", value: \.label) { p in
                    HStack(spacing: 5) {
                        Text(p.label)
                        if p.stale { Tag(text: "stale", color: .orange) }
                        if let idle = p.idleTag { Tag(text: idle, color: .secondary) }
                    }
                    .help("pid \(p.pid)")
                }
                .width(min: 140, ideal: 180)
                TableColumn("Folder", value: \.cwd) { p in
                    Text(Paths.abbreviate(p.cwd)).foregroundStyle(.secondary).truncationMode(.middle)
                }
                TableColumn("Started by", value: \.sessionText) { p in Text(p.sessionText).foregroundStyle(.secondary) }
                    .width(min: 70, ideal: 100)
                TableColumn("Memory", value: \.rssBytes) { p in Num(text: human(bytes: Int64(p.rssBytes))) }
                    .width(min: 64, ideal: 76, max: 90)
                TableColumn("Up", value: \.started) { p in Num(text: p.uptime) }
                    .width(min: 56, ideal: 64, max: 80)
                TableColumn("") { p in ProcessAction(p: p, s: s) }
                    .width(28)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .contextMenu(forSelectionType: pid_t.self) { ids in
                Button("Reveal folder in Finder") { reveal(ids) }
            } primaryAction: { reveal($0) }
            MCPCleanupNote(s: s, mcp: s.procs.filter { $0.kind == "mcp" })
            Footnote(text: "Watched: \(s.config.processes.names.joined(separator: ", ")). A process is stale when its parent died or its folder is gone. Double-click to reveal its folder.")
        }
    }

    func reveal(_ ids: Set<pid_t>) {
        for p in s.procs where ids.contains(p.pid) && !p.cwd.isEmpty { m.reveal(p.cwd) }
    }
}

struct SimulatorsPage: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot

    var body: some View {
        let sims = s.sims ?? []
        VStack(alignment: .leading, spacing: 10) {
            Table(sims) {
                TableColumn("Simulator") { sim in
                    HStack(spacing: 5) {
                        Text(sim.name)
                        if sim.usage.projectGone { Tag(text: "project gone", color: .orange) }
                    }
                    .help(sim.usage.detail)
                }
                TableColumn("Running") { sim in Text(sim.usage.apps.map(\.name).joined(separator: ", ")) }
                TableColumn("Project") { sim in Text(sim.usage.projectShort ?? "").foregroundStyle(.secondary) }
                TableColumn("Started with") { sim in
                    Text([sim.usage.tool, sim.usage.launcher.map { "from " + $0 }].compactMap { $0 }.joined(separator: " "))
                        .foregroundStyle(.secondary)
                }
                TableColumn("") { sim in SimAction(sim: sim) }
                    .width(28)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            if sims.count > 1 {
                Button("Shut down all \(sims.count)") { m.act("sims") { Actions.shutdownAllSims(sims) } }
                    .disabled(m.running.contains("sims"))
            }
        }
    }
}

extension WorktreeUnit {
    var sortKB: Int64 { outputKB ?? -1 }
    var branchText: String { branches.joined(separator: ", ") }
    var outputText: String {
        if outputs.isEmpty { return "none" }
        let parts = breakdown.prefix(2).map { "\($0.name) \(human(kb: $0.kb))" }
        return parts.isEmpty ? "measuring…" : parts.joined(separator: " · ")
    }
}

struct WorktreesPage: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot
    @State private var order = [KeyPathComparator(\WorktreeUnit.sortKB, order: .reverse)]
    @State private var selection = Set<String>()
    @State private var filter = ""

    var body: some View {
        let rows = s.worktrees.filter {
            filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.group.localizedCaseInsensitiveContains(filter)
                || $0.branchText.localizedCaseInsensitiveContains(filter)
        }
        VStack(alignment: .leading, spacing: 10) {
            FilterField(text: $filter)
            Table(rows.sorted(using: order), selection: $selection, sortOrder: $order) {
                TableColumn("Worktree", value: \.name) { u in
                    HStack(spacing: 5) {
                        Text(u.name)
                        ForEach(u.tags, id: \.self) { Tag(text: $0, color: $0 == "merged" ? .orange : .secondary) }
                    }
                    .help(Paths.abbreviate(u.path))
                }
                .width(min: 140, ideal: 200)
                TableColumn("Repo", value: \.group) { u in Text(u.group).foregroundStyle(.secondary) }
                    .width(min: 60, ideal: 80)
                TableColumn("Branch", value: \.branchText) { u in Text(u.branchText).foregroundStyle(.secondary).truncationMode(.middle) }
                TableColumn("Build output", value: \.sortKB) { u in
                    Num(text: u.outputs.isEmpty ? "none" : human(kb: u.outputKB))
                        .foregroundStyle(u.outputs.isEmpty ? .tertiary : .primary)
                        .help(u.outputText)
                }
                .width(min: 70, ideal: 80, max: 100)
                TableColumn("Last used", value: \.lastActivity) { u in Num(text: u.activityText) }
                    .width(min: 60, ideal: 70, max: 90)
                TableColumn("") { u in WorktreeAction(u: u) }
                    .width(50)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Reveal in Finder") { ids.forEach { m.reveal($0) } }
            } primaryAction: { $0.forEach { m.reveal($0) } }
            if s.worktrees.contains(where: \.hasClonableOutput) {
                Footnote(text: "node_modules and vendor are often copy-on-write clones, which share disk with the original, so cleaning frees less than shown.")
            }
            if m.measuringWorktrees {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Measuring build output…")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

extension Listener {
    var folderText: String { folder ?? "" }
}

struct PortsPage: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot
    @State private var order = [KeyPathComparator(\Listener.port)]
    @State private var selection = Set<pid_t>()

    var body: some View {
        let cfg = s.config.ports
        VStack(alignment: .leading, spacing: 10) {
            Table(s.ports.sorted(using: order), selection: $selection, sortOrder: $order) {
                TableColumn("Port", value: \.port) { l in Text(l.portList).monospacedDigit() }
                    .width(min: 60, ideal: 80, max: 120)
                TableColumn("Server", value: \.kind) { l in
                    HStack(spacing: 5) {
                        Text(l.kind)
                        ForEach(l.tags, id: \.self) { Tag(text: $0, color: $0 == "folder gone" ? .orange : .secondary) }
                    }
                    .help(l.help)
                }
                .width(min: 120, ideal: 200)
                TableColumn("Folder", value: \.folderText) { l in Text(l.folderText).foregroundStyle(.secondary) }
                TableColumn("Memory", value: \.bytes) { l in Num(text: human(bytes: Int64(l.bytes))) }
                    .width(min: 64, ideal: 76, max: 90)
                TableColumn("Up", value: \.started) { l in Num(text: l.uptime) }
                    .width(min: 56, ideal: 64, max: 80)
                TableColumn("") { l in PortAction(l: l) }
                    .width(50)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .contextMenu(forSelectionType: pid_t.self) { ids in
                Button("Open in browser") { open(ids) }
                Button("Reveal folder in Finder") {
                    for l in s.ports where ids.contains(l.pid) && !l.cwd.isEmpty && !l.folderGone { m.reveal(l.cwd) }
                }
            } primaryAction: { open($0) }
            Footnote(text: "Your own servers on ports \(cfg.minPort)–\(cfg.maxPort), reachable only from this Mac unless tagged. App helpers and system services are left out. Double-click to open one in the browser.")
        }
    }

    func open(_ ids: Set<pid_t>) {
        for l in s.ports where ids.contains(l.pid) { if let u = l.url { m.open(u) } }
    }
}

// MARK: - Caches

extension DerivedEntry {
    var sortKB: Int64 { sizeKB ?? -1 }
    var folderText: String { projectDir.map(Paths.abbreviate) ?? name }
}

extension CacheInfo {
    var sortKB: Int64 { sizeKB ?? -1 }
    var noteText: String { note ?? "" }
}

private struct FilterField: View {
    @Binding var text: String

    var body: some View {
        TextField("Filter", text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 240)
    }
}

struct XcodePage: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot
    @State private var order = [KeyPathComparator(\DerivedEntry.sortKB, order: .reverse)]
    @State private var selection = Set<String>()
    @State private var filter = ""

    var body: some View {
        let top = Double(s.derived.compactMap(\.sizeKB).max() ?? 1)
        let idle = s.config.xcode.idleDays
        let rows = s.derived.filter {
            filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) || $0.folderText.localizedCaseInsensitiveContains(filter)
        }
        VStack(alignment: .leading, spacing: 10) {
            FilterField(text: $filter)
            Table(rows.sorted(using: order), selection: $selection, sortOrder: $order) {
                TableColumn("Project", value: \.title) { e in
                    HStack(spacing: 5) {
                        Text(e.title)
                        ForEach(e.tags(idleDays: idle), id: \.self) { Tag(text: $0, color: $0 == "building" ? .secondary : .orange) }
                    }
                }
                .width(min: 150, ideal: 220)
                TableColumn("Folder", value: \.folderText) { e in
                    Text(e.folderText).foregroundStyle(e.status == .orphan ? .tertiary : .secondary).truncationMode(.middle)
                }
                TableColumn("Size", value: \.sortKB) { e in Num(text: human(kb: e.sizeKB)) }
                    .width(min: 60, ideal: 70, max: 90)
                TableColumn("", value: \.sortKB) { e in Bar(value: Double(max(e.sortKB, 0)) / top, color: Color.secondary.opacity(0.6), height: 5) }
                    .width(min: 40, ideal: 90)
                TableColumn("Last built", value: \.lastBuilt) { e in
                    Num(text: e.idleDays == 0 ? "today" : (e.idleDays == 1 ? "yesterday" : "\(e.idleDays) days ago"))
                }
                .width(min: 70, ideal: 84, max: 100)
                TableColumn("") { e in DerivedAction(e: e, root: s.derivedDataRoot) }
                    .width(28)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Reveal build cache in Finder") { reveal(ids, project: false) }
                Button("Reveal project in Finder") { reveal(ids, project: true) }
            } primaryAction: { reveal($0, project: false) }
            HStack {
                SizesNote(s: s)
                Spacer()
                Footnote(text: "Protected projects (xcode.protect) are never cleaned in bulk.")
            }
        }
    }

    func reveal(_ ids: Set<String>, project: Bool) {
        for e in s.derived where ids.contains(e.id) {
            if project, let dir = e.projectDir, e.status != .orphan { m.reveal(dir) } else if !project { m.reveal(e.path) }
        }
    }
}

struct CachesPage: View {
    @EnvironmentObject var m: Monitor
    let s: Snapshot
    @State private var order = [KeyPathComparator(\CacheInfo.sortKB, order: .reverse)]
    @State private var selection = Set<String>()

    var body: some View {
        let top = Double(s.caches.compactMap(\.sizeKB).max() ?? 1)
        VStack(alignment: .leading, spacing: 10) {
            Table(s.caches.sorted(using: order), selection: $selection, sortOrder: $order) {
                TableColumn("Cache", value: \.name)
                    .width(min: 90, ideal: 120)
                TableColumn("Folder", value: \.path) { c in Text(Paths.abbreviate(c.path)).foregroundStyle(.secondary).truncationMode(.middle) }
                TableColumn("Size", value: \.sortKB) { c in Num(text: human(kb: c.sizeKB)) }
                    .width(min: 60, ideal: 70, max: 90)
                TableColumn("", value: \.sortKB) { c in Bar(value: Double(max(c.sortKB, 0)) / top, color: Color.secondary.opacity(0.6), height: 5) }
                    .width(min: 40, ideal: 90)
                TableColumn("Note", value: \.noteText) { c in Text(c.noteText).foregroundStyle(.secondary) }
                TableColumn("") { c in CacheAction(c: c) }
                    .width(28)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Reveal in Finder") { reveal(ids) }
            } primaryAction: { reveal($0) }
            SizesNote(s: s)
        }
    }

    func reveal(_ ids: Set<String>) {
        for c in s.caches where ids.contains(c.id) { m.reveal(c.path) }
    }
}

// MARK: - Activity

/// One line of the timeline: a single action, or a bulk run ("clean all") with its items.
struct ActionGroup: Identifiable {
    let id: Int
    let entries: [ActionEntry]  // newest first
    var batch: String? { entries.count > 1 || entries[0].batch != nil ? entries[0].batch : nil }
    var time: Date { entries[0].time }
    var disk: Int64 { entries.reduce(0) { $0 + ($1.diskFreedBytes ?? 0) } }
    var memory: Int64 { entries.reduce(0) { $0 + ($1.memoryFreedBytes ?? 0) } }
    var failed: [ActionEntry] { entries.filter { $0.result != "ok" } }
}

struct ActivityPage: View {
    @EnvironmentObject var m: Monitor
    let entries: [ActionEntry]
    @State private var filter = 0

    /// Entries of one bulk run sit next to each other in the log; they become one group.
    static func grouped(_ entries: [ActionEntry]) -> [ActionGroup] {
        var out: [[ActionEntry]] = []
        for e in entries {
            if let b = e.batch, let last = out.last?.last, last.batch == b, last.time.timeIntervalSince(e.time) < 300 {
                out[out.count - 1].append(e)
            } else {
                out.append([e])
            }
        }
        return out.enumerated().map { ActionGroup(id: $0.offset, entries: $0.element) }
    }

    static func summary(_ entries: [ActionEntry]) -> String? {
        let week = entries.filter { Date().timeIntervalSince($0.time) <= 7 * 86400 }
        let disk = week.reduce(Int64(0)) { $0 + ($1.diskFreedBytes ?? 0) }
        let mem = week.reduce(Int64(0)) { $0 + ($1.memoryFreedBytes ?? 0) }
        var parts: [String] = []
        if disk > 0 { parts.append("\(human(bytes: disk)) of disk") }
        if mem > 0 { parts.append("\(human(bytes: mem)) of memory") }
        return parts.isEmpty ? nil : "Freed " + parts.joined(separator: " and ") + " in 7 days"
    }

    var body: some View {
        let groups = Self.grouped(entries).filter { g in
            switch filter {
            case 1: return g.disk > 0
            case 2: return g.memory > 0
            case 3: return !g.failed.isEmpty
            default: return true
            }
        }
        let days = Dictionary(grouping: groups) { Calendar.current.startOfDay(for: $0.time) }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("", selection: $filter) {
                    Text("All").tag(0)
                    Text("Freed disk").tag(1)
                    Text("Freed memory").tag(2)
                    Text("Errors").tag(3)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
                Spacer()
                Button("Show log in Finder") { m.reveal(ActionLog.file) }
                    .buttonStyle(.link).font(.caption)
                    .disabled(!FileManager.default.fileExists(atPath: ActionLog.file))
            }
            if groups.isEmpty {
                Footnote(text: entries.isEmpty
                         ? "Nothing yet. Everything Lapang deletes, kills, stops or shuts down, from the menu bar, this window or the lapang command, is listed here for 30 days."
                         : "Nothing matches.")
                    .padding(.top, 8)
            }
            ForEach(days.keys.sorted(by: >), id: \.self) { day in
                VStack(alignment: .leading, spacing: 2) {
                    Text(dayTitle(day)).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 4)
                    ForEach(days[day]!.sorted { $0.time > $1.time }) { ActionRow(group: $0, showSource: true, nested: true) }
                }
            }
            Footnote(text: "Kept for 30 days in \(Paths.abbreviate(ActionLog.file)). It never leaves this Mac.")
                .padding(.top, 4)
        }
        .frame(maxWidth: 820, alignment: .leading)
    }

    func dayTitle(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }
}

/// A timeline row: a dot on the line, the time, what was done, where from, what it freed.
struct ActionRow: View {
    let group: ActionGroup
    let showSource: Bool
    let nested: Bool

    var body: some View {
        let head = group.entries[0]
        let failed = !group.failed.isEmpty
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .strokeBorder(failed || group.batch != nil ? Color.orange : Color.secondary.opacity(0.6), lineWidth: 1.5)
                .frame(width: 9, height: 9)
                .padding(.top, 4)
            Text(head.time.formatted(date: .omitted, time: .shortened))
                .foregroundStyle(.tertiary).monospacedDigit()
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(headline).fontWeight(.medium).lineLimit(1)
                    if nested {
                        Text(detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    if showSource {
                        Text(head.source == "cli" ? "lapang command" : "menu bar or window").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    Text(outcome).foregroundStyle(failed ? Color.orange : Color.secondary).monospacedDigit().lineLimit(1)
                        .layoutPriority(1)
                }
                if !nested {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if nested && group.batch != nil {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(group.entries.enumerated()), id: \.offset) { _, e in
                            HStack(spacing: 6) {
                                Text(e.action.prefix(1).uppercased() + e.action.dropFirst())
                                Text(e.title).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(e.outcome).foregroundStyle(e.result == "ok" ? Color.secondary : Color.orange).monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
                }
                if nested && group.batch == nil, head.result != "ok", let what = head.target["path"] ?? head.target["cwd"] {
                    Text(Paths.abbreviate(what)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .font(.callout)
        .help(help(head))
    }

    var headline: String {
        let s = group.batch ?? group.entries[0].action
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    var detail: String {
        group.batch == nil ? group.entries[0].title : "\(group.entries.count) items"
    }

    var outcome: String {
        if group.batch == nil { return group.entries[0].outcome }
        var freed: [String] = []
        if group.disk > 0 { freed.append(human(bytes: group.disk)) }
        if group.memory > 0 { freed.append(human(bytes: group.memory) + " RAM") }
        let failed = group.failed.count
        let head = freed.isEmpty ? "ok" : freed.joined(separator: " + ")
        return failed > 0 ? head + " · \(failed) failed" : head
    }

    func help(_ e: ActionEntry) -> String {
        e.target.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }
}

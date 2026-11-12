// Lapang — a menu bar app that keeps an eye on the things that quietly fill a developer's Mac:
// free disk space (with a 24-hour chart), swap, booted simulators, stray dev processes, Xcode
// build caches and package caches, plus any custom sections you add in ~/.config/lapang.

import AppKit
import ServiceManagement
import SwiftUI

@main
struct LapangApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var monitor: Monitor

    init() {
        CLI.runIfRequested()  // `lapang status` etc. print and exit before any UI starts
        // `Lapang --render out.png [--demo] [--light]` draws the full panel off-screen and exits.
        // --demo uses built-in sample data instead of this Mac's; --light forces the light appearance.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            _monitor = StateObject(wrappedValue: Monitor(startTimer: false))
            let out = args[i + 1]
            Task { @MainActor in await renderPanel(to: out) }
        } else {
            Self.placeNearRightOnFirstLaunch()
            let m = Monitor()
            AppDelegate.monitor = m
            _monitor = StateObject(wrappedValue: m)
        }
    }

    /// macOS adds new menu bar items at the far left, next to the notch, which is exactly where a
    /// full menu bar hides them. On first launch only, start near the right instead (the position
    /// is in points from the screen's right edge). Once the user Cmd-drags it, macOS saves their
    /// spot under the same key and this never runs again.
    private static func placeNearRightOnFirstLaunch() {
        let key = "NSStatusItem Preferred Position Item-0"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(280.0, forKey: key)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Panel().environmentObject(monitor)
        } label: {
            MenuLabel(snap: monitor.snap)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuLabel: View {
    let snap: Snapshot?

    var body: some View {
        // Kept narrow: on a notched MacBook, menu bar items that don't fit are silently hidden.
        if let s = snap {
            let alert = s.diskLevel != .ok || s.pressureLevel == .crit || s.forecastWarning
            if alert {
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("\(Int(s.freeGB))G")
                }
            } else {
                Text("\(Int(s.freeGB))G")
            }
        } else {
            Image(systemName: "internaldrive")
        }
    }
}

@MainActor
func renderPanel(to path: String) async {
    let m = Monitor(startTimer: false)
    let args = CommandLine.arguments
    if args.contains("--demo") {
        m.snap = Demo.snapshot()
        m.updated = Date()
        m.frozen = true
    } else {
        await m.refresh()
    }
    if !args.contains("--demo"), SizeStore.shared.isDue, let s = m.snap {
        let paths = s.measuredPaths
        await Task.detached { SizeStore.shared.measure(paths) }.value
        await m.refresh()
    }
    if !args.contains("--demo"), let s = m.snap, case let due = WorktreeSizes.shared.due(s.worktrees), !due.isEmpty {
        let listed = Set(s.worktrees.flatMap(\.outputs))
        await Task.detached { WorktreeSizes.shared.measure(due, keeping: listed) }.value
        await m.refresh()
    }
    let open = renderOpenFolds(args)
    let root = VStack(spacing: 0) {
        Panel(scroll: false)
        // a menu can't be drawn off-screen, so `--open "Recent actions"` lists its lines under the panel
        if open?.contains("Recent actions") == true { RecentActionsPreview() }
    }
    .environmentObject(m)
    .environment(\.openFolds, open)
    .background(Color(nsColor: .windowBackgroundColor))
    let view = NSHostingView(rootView: root)
    if args.contains("--light") { view.appearance = NSAppearance(named: .aqua) }
    let size = view.fittingSize
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                          backing: .buffered, defer: false)
    window.contentView = view
    view.frame = NSRect(origin: .zero, size: size)
    view.layoutSubtreeIfNeeded()
    try? await Task.sleep(nanoseconds: 500_000_000)
    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    exit(0)
}

struct Panel: View {
    @EnvironmentObject var m: Monitor
    var scroll = true
    @State private var contentHeight: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            if let s = m.snap {
                if scroll {
                    // as tall as the content, scrolling only past 640 pt
                    ScrollView {
                        content(s).background(GeometryReader { g in
                            Color.clear.preference(key: HeightKey.self, value: g.size.height)
                        })
                    }
                    .frame(height: min(contentHeight, 640))
                    .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
                } else {
                    content(s)
                }
            } else {
                ProgressView("Looking around…").padding(40)
            }
            Footer()
        }
        .frame(width: 380)
        .onAppear { Task { await m.refresh() } }
    }

    func content(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let e = s.configError {
                Text(e).font(.caption).foregroundStyle(.orange).padding([.horizontal, .top], 14)
            }
            Header(s: s)
            ChoresBlock(s: s)
            if !s.memUsers.isEmpty { MemoryUsersFold(s: s) }
            GrowthFold(s: s)
            if !s.derived.isEmpty { XcodeFold(s: s) }
            if !s.worktrees.isEmpty { WorktreesFold(s: s) }
            if !s.caches.isEmpty { CachesFold(s: s) }
            if !s.config.processes.names.isEmpty { ProcessFold(s: s) }
            PortsFold(s: s)
            if s.sims != nil { SimFold(s: s) }
            ForEach(s.sections) { CustomFold(state: $0) }
        }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct Footer: View {
    @EnvironmentObject var m: Monitor
    @State private var atLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        HStack(spacing: 10) {
            if let msg = m.message {
                Text(msg).font(.caption).lineLimit(1).truncationMode(.tail)
            } else if let u = m.updated {
                Text("Updated \(u.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if m.refreshing { ProgressView().controlSize(.mini) }
            Spacer()
            Button { Task { await m.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh now")
            Menu {
                Button("Share snapshot…") { ShareWindow.show(m) }
                Divider()
                Toggle("Open at login", isOn: Binding(get: { atLogin }, set: setLogin))
                Toggle(mcpToggleTitle, isOn: Binding(get: { m.snap?.config.processes.mcpCleanup.enabled ?? false },
                                                     set: { m.setMCPCleanup($0) }))
                Divider()
                Button("Edit config…") { m.editConfig() }
                Button("Re-measure folder sizes") { m.measure() }
                Button("Show data folder") { m.reveal(Paths.support) }
                Menu("Recent actions") {
                    let recent = ActionLog.recent(10)
                    if recent.isEmpty { Text("Nothing yet") }
                    ForEach(Array(recent.enumerated()), id: \.offset) { Text($0.element.line) }
                    Divider()
                    Button("Show log in Finder") { m.reveal(ActionLog.file) }
                        .disabled(!FileManager.default.fileExists(atPath: ActionLog.file))
                }
                Divider()
                Button("Quit Lapang") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    var mcpToggleTitle: String {
        let h = m.snap?.config.processes.mcpCleanup.idleHours ?? 2
        return "Stop idle MCP servers (\(hoursLabel(h))+)"
    }

    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            m.flash("Open at login: \(error.localizedDescription)")
        }
        atLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct RecentActionsPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent actions").font(.caption).foregroundStyle(.secondary)
            let recent = ActionLog.recent(10)
            if recent.isEmpty { Text("Nothing yet") }
            ForEach(Array(recent.enumerated()), id: \.offset) { Text($0.element.line) }
            Divider()
            Text("Show log in Finder")
        }
        .font(.callout).lineLimit(1)
        .frame(width: 380, alignment: .leading)
        .padding(12)
        .overlay(alignment: .top) { Divider() }
    }
}

/// `--open "Simulators,Memory"` forces those sections open in a render; --demo defaults to two.
private func renderOpenFolds(_ args: [String]) -> Set<String>? {
    if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
        return Set(args[i + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }
    return args.contains("--demo") ? ["What grew", "Xcode build caches"] : nil
}

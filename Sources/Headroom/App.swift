// Headroom — a menu bar app that keeps an eye on the things that quietly fill a developer's Mac:
// free disk space (with a 24-hour chart), swap, booted simulators, stray dev processes, Xcode
// build caches and package caches, plus any custom sections you add in ~/.config/headroom.

import AppKit
import ServiceManagement
import SwiftUI

@main
struct HeadroomApp: App {
    @StateObject private var monitor: Monitor

    init() {
        // `Headroom --render out.png` draws the full panel off-screen and exits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            _monitor = StateObject(wrappedValue: Monitor(startTimer: false))
            let out = args[i + 1]
            Task { @MainActor in await renderPanel(to: out) }
        } else {
            _monitor = StateObject(wrappedValue: Monitor())
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
    await m.refresh()
    if SizeStore.shared.isDue, let s = m.snap {
        let paths = s.measuredPaths
        await Task.detached { SizeStore.shared.measure(paths) }.value
        await m.refresh()
    }
    let root = Panel(scroll: false).environmentObject(m).background(Color(nsColor: .windowBackgroundColor))
    let view = NSHostingView(rootView: root)
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

    var body: some View {
        VStack(spacing: 0) {
            if let s = m.snap {
                if scroll {
                    ScrollView { content(s) }.frame(height: 640)
                } else {
                    content(s)
                }
            } else {
                ProgressView("Looking around…").padding(40)
            }
            Divider()
            Footer()
        }
        .frame(width: 400)
        .onAppear { Task { await m.refresh() } }
    }

    func content(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let e = s.configError {
                Text(e).font(.caption).foregroundStyle(.orange)
            }
            DiskBox(s: s)
            MemoryBox(s: s)
            if s.sims != nil { SimBox(s: s) }
            if !s.config.processes.names.isEmpty { ProcessBox(s: s) }
            if !s.derived.isEmpty { XcodeBox(s: s) }
            if !s.caches.isEmpty { CachesBox(s: s) }
            ForEach(s.sections) { CustomBox(state: $0) }
        }
        .padding(12)
    }
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
                Toggle("Open at login", isOn: Binding(get: { atLogin }, set: setLogin))
                Divider()
                Button("Edit config…") { m.editConfig() }
                Button("Re-measure folder sizes") { m.measure() }
                Button("Show data folder") { m.reveal(Paths.support) }
                Divider()
                Button("Quit Headroom") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
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

import AppKit
import Foundation
import UserNotifications

@MainActor
final class Monitor: ObservableObject {
    @Published var snap: Snapshot?
    @Published var updated: Date?
    @Published var running: Set<String> = []
    @Published var refreshing = false
    @Published var measuring = false
    @Published var message: String?
    private var timer: Timer?
    private var interval: TimeInterval = 60
    private var lastNotified: Date?

    init(startTimer: Bool = true) {
        guard startTimer else { return }
        Task { await refresh() }
        schedule(60)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func schedule(_ seconds: TimeInterval) {
        timer?.invalidate()
        interval = seconds
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        if refreshing { return }
        refreshing = true
        defer { refreshing = false }
        let previous = snap?.sections ?? []
        let s = await Task.detached { Engine.snapshot(sectionsFrom: previous) }.value
        snap = s
        updated = Date()
        let wanted = TimeInterval(max(15, s.config.refreshSeconds))
        if wanted != interval { schedule(wanted) }
        alertIfLow(s)
        if SizeStore.shared.isDue { measure() }
    }

    func measure() {
        guard let s = snap, !measuring else { return }
        measuring = true
        let paths = [s.derivedDataRoot] + s.derived.map(\.path) + s.caches.map(\.path)
        Task {
            await Task.detached { SizeStore.shared.measure(paths) }.value
            measuring = false
            await refresh()
        }
    }

    private func alertIfLow(_ s: Snapshot) {
        guard s.config.disk.notify else { return }
        guard s.diskLevel != .ok else { lastNotified = nil; return }
        if let t = lastNotified, Date().timeIntervalSince(t) < 6 * 3600 { return }
        lastNotified = Date()
        let c = UNMutableNotificationContent()
        c.title = s.diskLevel == .crit ? "Disk almost full" : "Disk getting full"
        c.body = String(format: "%.0f GB free. Open Headroom in the menu bar to clean up.", s.freeGB)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "disk", content: c, trigger: nil))
    }

    /// Runs `work` off the main thread with a spinner on `key`, then refreshes.
    func act(_ key: String, confirm: Confirm? = nil, _ work: @escaping @Sendable () -> String?) {
        if let c = confirm, !Self.ask(c) { return }
        running.insert(key)
        Task {
            let msg = await Task.detached { work() }.value
            running.remove(key)
            if let msg { flash(msg) }
            await refresh()
        }
    }

    func flash(_ text: String) {
        message = text
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if message == text { message = nil }
        }
    }

    struct Confirm {
        let title: String
        let message: String
        let button: String
    }

    static func ask(_ c: Confirm) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = c.title
        a.informativeText = c.message
        a.alertStyle = .warning
        a.addButton(withTitle: c.button).hasDestructiveAction = true
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Paths.expand(path))])
    }

    func open(_ link: String) {
        if let u = URL(string: link) { NSWorkspace.shared.open(u) }
    }

    func editConfig() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Config.ensureFile()))
    }
}

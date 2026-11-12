import AppKit
import SwiftUI

/// The Lapang window: the whole picture at once, next to the menu bar panel for quick glances.
/// It opens from Spotlight, Finder or the Dock, from the panel's window button or gear menu, and
/// with ⌘0 while Lapang is active. On a notched MacBook a full menu bar can hide the menu bar
/// item, so this is also the way back in.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var monitor: Monitor?
    private static weak var shared: AppDelegate?
    private var window: NSWindow?
    private var keys: Any?

    override init() {
        super.init()
        Self.shared = self
    }

    static func openWindow() { shared?.showWindow() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Self.monitor != nil else { return }  // an off-screen render
        installShortcuts()
        // Opened by hand: show the window. Started at login: stay in the menu bar.
        // The launch event is only readable now; show the window once launch has settled.
        guard !launchedAtLogin() else { return }
        DispatchQueue.main.async { [weak self] in self?.showWindow() }
    }

    /// Called when Lapang is opened again while it's already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func showWindow() {
        guard let m = Self.monitor else { return }
        if window == nil {
            let host = NSHostingController(rootView: MainWindow().environmentObject(m))
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "Lapang"
            w.isReleasedWhenClosed = false
            w.contentMinSize = MainWindow.minSize
            w.setContentSize(MainWindow.defaultSize)
            w.center()
            // restores the size and place it had last time, and saves them as it changes
            w.setFrameAutosaveName("LapangMainWindow")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Lapang has no menu bar of its own, so the window's keys are handled here: ⌘0 opens it
    /// (from the panel too), ⌘W closes it, ⌘R refreshes.
    private func installShortcuts() {
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return e }
            switch e.charactersIgnoringModifiers {
            case "0":
                showWindow()
                return nil
            case "w" where e.window != nil && e.window === window:
                window?.performClose(nil)
                return nil
            case "r" where e.window != nil && e.window === window:
                Task { await Self.monitor?.refresh() }
                return nil
            default:
                return e
            }
        }
    }

    private func launchedAtLogin() -> Bool {
        guard let e = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return e.eventID == kAEOpenApplication
            && e.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

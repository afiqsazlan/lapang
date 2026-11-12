import AppKit
import SwiftUI

/// Opening Lapang from Spotlight, Finder or the Dock shows the panel in a normal window.
/// On a notched MacBook a full menu bar hides the menu bar item, so this is the way back in.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var monitor: Monitor?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opened by hand: show the window. Started at login: stay in the menu bar.
        // The launch event is only readable now; show the window once launch has settled.
        guard !launchedAtLogin() else { return }
        DispatchQueue.main.async { [weak self] in
            if Self.monitor != nil { self?.showWindow() }
        }
    }

    /// Called when Lapang is opened again while it's already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func showWindow() {
        guard let m = Self.monitor else { return }
        if window == nil {
            // the window follows the panel's height as sections open and close
            let vc = NSHostingController(rootView: Panel().environmentObject(m))
            vc.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: vc)
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.title = "Lapang"
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("LapangWindow")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func launchedAtLogin() -> Bool {
        guard let e = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return e.eventID == kAEOpenApplication
            && e.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

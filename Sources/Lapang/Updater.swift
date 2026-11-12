import AppKit
import Combine
import Sparkle
import UserNotifications

/// In-app updates through Sparkle. Once a day Lapang fetches the appcast from afiqsazlan.com,
/// its only network request. Builds made with ./build.sh carry no feed URL, so for them this is off
/// and they update with `git pull && ./build.sh`.
///
/// Lapang lives in the menu bar, so an update found by the daily check doesn't jump in front
/// of your work: it waits behind a notification and an "Update to …" item in the gear menu.
@MainActor
final class Updater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()
    static let notificationID = "lapang.update"

    @Published private(set) var canCheck = false
    @Published private(set) var available: String?
    private var controller: SPUStandardUpdaterController?

    var enabled: Bool { controller != nil }

    var automaticChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    /// Starts the updater in the running app; never for the command line or off-screen renders.
    func start() {
        guard controller == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        controller = c
        c.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheck)
    }

    func check() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    // MARK: gentle reminders for a menu bar app

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                         andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        let version = update.displayVersionString
        Task { @MainActor in
            self.available = version
            guard !handleShowingUpdate, !state.userInitiated else { return }
            let content = UNMutableNotificationContent()
            content.title = "Lapang \(version) is available"
            content.body = "Click to see what's new and update."
            let req = UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(req)
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.available = nil }
    }
}

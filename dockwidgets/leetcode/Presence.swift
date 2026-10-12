import AppKit
import CoreGraphics

/// Whether anyone can be looking at the numbers: the screen is unlocked and the Mac (and its
/// display) is awake. A dock widget polling an API has no reason to run otherwise,
/// so the model starts and stops its polling loop from `onChange`.
@MainActor
final class Presence {
    private(set) var locked = Presence.screenLocked()
    private(set) var asleep = false
    var active: Bool { !locked && !asleep }
    /// Called after any change, so the owner can start polling again (or stop).
    var onChange: (() -> Void)?

    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        watch(distributed, "com.apple.screenIsLocked") { $0.locked = true }
        watch(distributed, "com.apple.screenIsUnlocked") { $0.locked = false }
        watch(workspace, NSWorkspace.willSleepNotification.rawValue) { $0.asleep = true }
        watch(workspace, NSWorkspace.didWakeNotification.rawValue) { $0.asleep = false }
        watch(workspace, NSWorkspace.screensDidSleepNotification.rawValue) { $0.asleep = true }
        watch(workspace, NSWorkspace.screensDidWakeNotification.rawValue) { $0.asleep = false }
    }

    private func watch(_ center: NotificationCenter, _ name: String, _ apply: @escaping @MainActor (Presence) -> Void) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                apply(self)
                self.onChange?()
            }
        }
        tokens.append((center, token))
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens = []
        onChange = nil
    }

    /// The session's own lock flag, so a widget created while the screen is locked starts paused.
    static func screenLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}

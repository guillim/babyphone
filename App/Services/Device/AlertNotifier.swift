import Foundation
@preconcurrency import UserNotifications

/// The parent unit's system notifications, for when the app is not on screen.
enum AlertNotifier {
    private enum Identifier {
        static let noise = "noise"
        static let linkLost = "link-lost"
        static let power = "power"
        static let watchdog = "watchdog"
    }

    /// The watchdog fires this long after it was last pushed back.
    private static let watchdogDelay: TimeInterval = 90

    static func requestAuthorization() async {
        #if DEBUG
        // No simulator command can answer this prompt, so UI tests go without notifications.
        guard ProcessInfo.processInfo.environment["NID_UI_TEST_STATE"] == nil else { return }
        #endif
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func notifyNoise() {
        post(Identifier.noise, title: String(localized: "notification.noise.title"), body: String(localized: "notification.noise.body"))
    }

    static func notifyLinkLost() {
        post(Identifier.linkLost, title: String(localized: "notification.linkLost.title"), body: String(localized: "notification.linkLost.body"))
    }

    static func notifyPower(title: String) {
        post(Identifier.power, title: title, body: String(localized: "notification.power.body"))
    }

    /// Pushes back a notification that only fires if the app stops running.
    ///
    /// iOS can suspend or end a background app without warning, and an app that
    /// is not running cannot raise an alarm. So the alarm is scheduled ahead of
    /// time and postponed for as long as the app is alive to postpone it.
    static func postponeWatchdog() {
        post(
            Identifier.watchdog,
            title: String(localized: "notification.watchdog.title"),
            body: String(localized: "notification.watchdog.body"),
            after: watchdogDelay
        )
    }

    /// Removes every pending and delivered notification. Call when monitoring stops.
    static func clear() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    private static func post(_ identifier: String, title: String, body: String, after delay: TimeInterval? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // A baby monitor must get through a Sleep Focus.
        content.interruptionLevel = .timeSensitive
        let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
        // Reusing the identifier replaces the previous request.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
}

import UIKit
import UserNotifications

/// UIKit lifecycle glue for push: remote-notification registration and the
/// UNUserNotificationCenterDelegate callbacks SwiftUI's own lifecycle doesn't
/// expose. Hosted via @UIApplicationDelegateAdaptor in AlfredApp.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let config = ServerConfig.load()
        PushManager.shared.didReceiveDeviceToken(deviceToken, config: config)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Nothing to surface: Settings' Notifications section shows "not registered"
        // until a token arrives, which is enough signal for the user.
    }

    /// Shows a banner even while Alfred is in the foreground (brief part 3).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let content = notification.request.content
        let sessionId = content.userInfo["session_id"] as? String
        NotificationLog.shared.record(title: content.title, body: content.body, sessionId: sessionId)
        return [.banner, .sound, .list]
    }

    /// Tapping a notification with session_id opens that chat (brief part 3).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        if let sessionId = content.userInfo["session_id"] as? String {
            Navigator.shared.openSession(sessionId)
        }
    }
}

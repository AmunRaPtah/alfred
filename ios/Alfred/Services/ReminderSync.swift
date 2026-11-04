import Foundation
import UserNotifications

/// Local notification scheduling (brief part 4). On launch and on returning
/// to the foreground, fetches /reminders and replaces every pending local
/// notification carrying Alfred's identifier prefix with a fresh
/// UNCalendarNotificationTrigger set. iOS caps an app at 64 pending requests
/// total; this keeps the soonest 60 so there's headroom for other local
/// notifications the app might schedule.
enum ReminderSync {
    static let idPrefix = "org.zyco.alfred.reminder."
    private static let maxScheduled = 60

    static func sync(config: ServerConfig) async {
        guard config.isConfigured else { return }
        guard let reminders = try? await APIClient(config: config).reminders() else { return }

        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        if !ours.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ours) }

        let soonest = reminders
            .filter { $0.fireAt > Date() }
            .sorted { $0.fireAt < $1.fireAt }
            .prefix(maxScheduled)

        for r in soonest {
            let content = UNMutableNotificationContent()
            content.title = r.title.isEmpty ? "Alfred" : r.title
            content.body = r.body
            content.sound = .default
            if let sid = r.sessionId { content.userInfo = ["session_id": sid] }

            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: r.fireAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(identifier: idPrefix + r.id, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }
}

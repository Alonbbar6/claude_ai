import UserNotifications

/// A local "Time to head out" notification at the planned leave time. It
/// fires even if the app is suspended; it's rescheduled on every re-plan and
/// cleared once the food is ready or the order closes.
enum LeaveReminder {
    private static func id(_ orderId: String) -> String { "leave-\(orderId)" }

    /// Asked in context, at the first order, like real delivery apps.
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func schedule(orderId: String, at leaveAt: Date, restaurant: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id(orderId)])
        let seconds = leaveAt.timeIntervalSinceNow
        guard seconds > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Time to head out"
        content.body = "Leave now for \(restaurant) so you arrive as your food is ready."
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: id(orderId), content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)))
    }

    static func cancel(orderId: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id(orderId)])
    }

    /// Status changes while the app is open show as system notifications too.
    static func notify(orderId: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "status-\(orderId)-\(title)", content: content, trigger: nil))
    }
}

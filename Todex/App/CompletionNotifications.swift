import Foundation
import UserNotifications

/// Local "turn finished" alerts. The preference is a plain UserDefaults flag;
/// the system authorization is requested lazily when the user enables it.
enum CompletionNotifications {
    static let defaultsKey = "completionNotifications"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Post immediately (trigger: nil). The system drops the request silently
    /// when authorization has since been revoked, so no status check is needed.
    static func post(conversationId: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["conversationId": conversationId]
        let request = UNNotificationRequest(
            identifier: "turn-completed-\(conversationId)-\(UUID().uuidString)",
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

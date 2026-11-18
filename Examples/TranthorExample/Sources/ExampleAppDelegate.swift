import UIKit
import UserNotifications
import TranthorPush

/// The EXAMPLE owns its delegate. TranthorPush never assigns or swizzles a host delegate.
@MainActor
final class ExampleAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Each UI test owns its notification fixtures; previous banners must not
        // group with or obscure the next test's exact delivery identifier.
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            center.removeAllPendingNotificationRequests()
            center.removeAllDeliveredNotifications()
        }
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await ExamplePushModel.shared.receiveToken(deviceToken) }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        ExamplePushModel.shared.registrationFailed()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        // Copy a Sendable value; complete once before awaiting any SDK admission or disk I/O.
        let payload = PushNotification(userInfo: notification.request.content.userInfo)
        // Presentation is host policy and OS permission, independent of analytics consent.
        completionHandler([.banner, .sound, .badge])
        Task { await ExamplePushModel.shared.receive(payload, interaction: .foreground) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let payload = PushNotification(userInfo: response.notification.request.content.userInfo)
        let action = response.actionIdentifier
        let interaction: PushInteraction = action == UNNotificationDismissActionIdentifier ? .dismissed : .opened(actionIdentifier: action)
        completionHandler()
        Task { await ExamplePushModel.shared.receive(payload, interaction: interaction) }
    }
}

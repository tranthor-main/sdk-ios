#if canImport(UserNotifications)
import UserNotifications
import TranthorSDK

/// Asks for notification permission when your app calls it. It does not register with APNs or replace delegates.
public enum PushAuthorization {
    /// Shows the system permission prompt and returns whether the user granted it. Call `refreshPermission()` on
    /// `TranthorPush` afterwards so the server learns the new state.
    public static func request(options: UNAuthorizationOptions = [.alert, .sound, .badge]) async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: options)
    }
    /// The OS notification permission as `Installation Registered` reports it: authorized, provisional and
    /// ephemeral are `granted`, denied is `denied`, not yet asked is `unknown`. Never prompts.
    static func currentState() async -> InstallationPermission {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        default: .unknown
        }
    }
}
#endif

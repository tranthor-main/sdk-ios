import Foundation
import UserNotifications

/// The notification category the Tranthor server puts on every iPhone push (`aps.category = "TRANTHOR_PUSH"`).
///
/// iOS reports a dismissal to the app only for a notification whose category was registered with
/// `customDismissAction`. A bound ``TranthorPush`` registers it for you, merged into your own categories.
/// `setNotificationCategories(_:)` replaces the whole set, so register your categories before creating the
/// push instance, build your set with ``merged(into:)``, or call ``TranthorPush/registerNotificationCategory()``
/// after replacing the set.
public enum PushCategory {
    /// The category identifier the server puts on every iPhone push.
    public static let identifier = "TRANTHOR_PUSH"

    /// No actions, no intents, and the dismiss option.
    package static var category: UNNotificationCategory {
        UNNotificationCategory(identifier: identifier, actions: [], intentIdentifiers: [], options: [.customDismissAction])
    }

    /// `existing` plus the Tranthor category, every other category untouched. Nil when `existing` already has a
    /// category with this identifier: the host's own definition is never replaced.
    public static func merged(into existing: Set<UNNotificationCategory>) -> Set<UNNotificationCategory>? {
        guard !existing.contains(where: { $0.identifier == identifier }) else { return nil }
        var result = existing
        result.insert(category)
        return result
    }
}

/// A set of registered categories moved between isolation domains. `UNNotificationCategory` is not declared
/// Sendable, but an instance is an immutable value copy (it is `NSCopying` and has no setters), and this type
/// only ever holds sets that are read and passed on, never mutated.
struct CategorySnapshot: @unchecked Sendable { let categories: Set<UNNotificationCategory> }

protocol NotificationCategoryStore: Sendable {
    func categories() async -> CategorySnapshot
    func replace(with categories: CategorySnapshot) async
}

/// The real notification center. Never created in unit tests: `UNUserNotificationCenter.current()` needs an app bundle.
struct LiveCategoryStore: NotificationCategoryStore {
    // https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/getnotificationcategories(completionhandler:)
    func categories() async -> CategorySnapshot {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationCategories { continuation.resume(returning: CategorySnapshot(categories: $0)) }
        }
    }
    // https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/setnotificationcategories(_:)
    func replace(with snapshot: CategorySnapshot) async {
        UNUserNotificationCenter.current().setNotificationCategories(snapshot.categories)
    }
}

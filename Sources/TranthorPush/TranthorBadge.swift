import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Errors thrown by `TranthorBadge`.
public enum TranthorBadgeError: Error, Sendable, Equatable {
    /// The App Group container is unavailable: the group is not in this app's entitlements. The icon was still updated.
    case counterUnavailable
}

/// The app side of the badge +1 feature (`tranthor.badge == "increment"`).
///
/// The Notification Service Extension adds one to a count kept in the App Group container. Change the icon
/// badge only through this type, or call ``synchronize(_:appGroupIdentifier:)`` after other code changed it;
/// otherwise the extension's count drifts from the icon.
public enum TranthorBadge {
    /// Sets the icon badge to `count` and stores the same count for the extension.
    /// - Throws: ``TranthorBadgeError/counterUnavailable`` when the App Group container is unavailable; the icon is still set.
    public static func set(_ count: Int, appGroupIdentifier: String) async throws {
        let counter = BadgeCounter(appGroupIdentifier: appGroupIdentifier)
        try await set(count, counter: counter, applyToIcon: applyToIcon)
    }
    /// Sets the icon badge and the extension's count to zero.
    public static func clear(appGroupIdentifier: String) async throws {
        try await set(0, appGroupIdentifier: appGroupIdentifier)
    }
    /// Stores `count` for the extension without touching the icon, for apps that set the badge themselves.
    public static func synchronize(_ count: Int, appGroupIdentifier: String) throws {
        guard BadgeCounter(appGroupIdentifier: appGroupIdentifier)?.set(count) == true else { throw TranthorBadgeError.counterUnavailable }
    }

    /// The count and the icon change under one hold of the counter's file lock, so the extension's next +1 starts
    /// from `count`. If the lock cannot be had within two seconds, or the Task is cancelled while waiting, the icon is
    /// still set and `counterUnavailable` is thrown.
    static func set(_ count: Int, counter: BadgeCounter?, applyToIcon: @Sendable (Int) async throws -> Void) async throws {
        let value = max(0, count)
        guard let counter else { try await applyToIcon(value); throw TranthorBadgeError.counterUnavailable }
        var stored = false
        do {
            try await counter.withExclusiveAccess { locked in
                stored = locked.set(value)
                try await applyToIcon(value)
            }
        } catch BadgeCounter.LockError.timedOut {
            try await applyToIcon(value)
        }
        if !stored { throw TranthorBadgeError.counterUnavailable }
    }

    @Sendable private static func applyToIcon(_ count: Int) async throws {
        #if canImport(UserNotifications)
        if #available(iOS 16.0, macOS 13.0, *) {
            try await UNUserNotificationCenter.current().setBadgeCount(count)
            return
        }
        #endif
        #if canImport(UIKit)
        await MainActor.run { UIApplication.shared.applicationIconBadgeNumber = count }
        #endif
    }
}

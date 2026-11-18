import Foundation
import CryptoKit
@_exported import TranthorPushPayload

/// The APNs service a device token belongs to. Tokens are specific to one, so choose it from the app's signed
/// `aps-environment` entitlement: `development` for Xcode and Simulator builds, `production` for TestFlight and the App Store.
public enum APNsEnvironment: String, Sendable { case development, production }

/// Errors thrown by `TranthorPush`.
public enum PushError: Error, Sendable, Equatable {
    /// `PushConfiguration.bundleIdentifier` is not a valid reverse-DNS bundle identifier.
    case invalidBundleIdentifier
    /// `registerDeviceToken(_:)` was given empty data.
    case emptyDeviceToken
    /// The `TranthorPush` instance was shut down.
    case shutDown
}

/// What the user did with a notification. A foreground observation is not a delivery receipt: iOS reports a
/// notification as received only while the app is in the foreground.
public enum PushInteraction: Sendable, Equatable, Hashable {
    /// The notification arrived while the app was in the foreground.
    /// `opened(actionIdentifier:)` is a tap or action; `dismissed` is a swipe away.
    case foreground, opened(actionIdentifier: String), dismissed
}

/// A push interaction that `TranthorPush` reported to the SDK, passed to `PushConfiguration.onEvent`.
public struct PushEvent: Sendable, Equatable {
    /// The notification's delivery ID.
    public let deliveryID: String
    /// What the user did.
    public let interaction: PushInteraction
    /// The `messageId` of the SDK event, stable for one delivery and interaction.
    public let messageId: String

    init(deliveryID: String, interaction: PushInteraction) {
        self.deliveryID = deliveryID; self.interaction = interaction
        let action: String
        switch interaction {
        case .foreground: action = "received"
        case .opened(let id): action = "opened:\(id)"
        case .dismissed: action = "dismissed"
        }
        var bytes = Array(SHA256.hash(data: Data("TranthorPush:v1:\(deliveryID.utf8.count):\(deliveryID):\(action)".utf8)).prefix(16))
        // UUID v8: a custom SHA-256-derived stable ID, with RFC variant bits.
        bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
        messageId = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }
}

/// Settings for ``TranthorPush``.
public struct PushConfiguration: Sendable {
    /// The app's bundle identifier, reported as the Installation's app ID.
    public let bundleIdentifier: String
    /// The APNs service the app's tokens belong to.
    public let environment: APNsEnvironment
    /// How many handled notifications are remembered to ignore duplicates, clamped to 1...10,000.
    public let recentEventLimit: Int
    /// Called after each push interaction has been queued with the SDK. Optional.
    public let onEvent: @Sendable (PushEvent) async throws -> Void

    /// Creates a configuration. `bundleIdentifier` must be a reverse-DNS identifier such as `com.example.app`.
    public init(bundleIdentifier: String, environment: APNsEnvironment, recentEventLimit: Int = 1024,
                onEvent: @escaping @Sendable (PushEvent) async throws -> Void = { _ in }) {
        self.bundleIdentifier = bundleIdentifier; self.environment = environment
        self.recentEventLimit = max(1, min(recentEventLimit, 10_000))
        self.onEvent = onEvent
    }
}

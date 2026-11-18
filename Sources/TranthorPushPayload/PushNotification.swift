import Foundation
import CoreFoundation

/// The versioned payload the Tranthor server sends for an iPhone, read from `userInfo`:
///
///     {"aps":{...},"tranthor":{"version":1,"deliveryId":"…","imageUrl":"https://…","badge":"increment"},
///      "url":"https://… or an app link","<custom key>":"<string>"}
///
/// Only `tranthor.version` (the number 1) and `tranthor.deliveryId` are required. The SDK never opens
/// `url`: the host decides what a tap does (see ``url``).
public struct PushNotification: Sendable, Equatable {
    /// `tranthor.deliveryId`: identifies one send of a message to this device.
    public let deliveryID: String
    /// `tranthor.imageUrl`, unvalidated. The service extension checks it against its host allowlist.
    public let imageURL: String?
    /// The tap link: top-level `userInfo["url"]`, a web URL or an app link, or nil. It is **not** opened
    /// by the SDK and is not checked to be a URL; validate it before routing or opening it.
    public let url: String?
    /// The template's custom data: top-level string values other than `aps`, `tranthor` and `url`, and
    /// other than the keys the server reserves (`title`, `body`, `channelId`, `from`, `message_type`,
    /// `google.*`, `gcm.*`). Values that are not strings are ignored.
    public let data: [String: String]
    /// True when `tranthor.badge` is `"increment"`: the service extension adds one to the app badge.
    public let incrementsBadge: Bool

    /// Reads a Tranthor push from a notification's `userInfo`. Returns nil for any payload that is not one,
    /// so another SDK's notifications are left to it.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let marker = userInfo["tranthor"] as? [String: Any],
              let version = marker["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let id = marker["deliveryId"] as? String,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              id.utf8.count <= 128,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._:-".contains($0)) }) else { return nil }
        deliveryID = id
        imageURL = (marker["imageUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        incrementsBadge = (marker["badge"] as? String) == "increment"
        url = (userInfo["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var custom: [String: String] = [:]
        for (key, value) in userInfo {
            guard let key = key as? String, let value = value as? String, !Self.isReserved(key) else { continue }
            custom[key] = value
        }
        data = custom
    }

    /// Keys the server reserves in the payload; they are never custom data.
    static func isReserved(_ key: String) -> Bool {
        ["aps", "tranthor", "title", "body", "channelId", "url", "from", "message_type"].contains(key)
            || key.hasPrefix("google.") || key.hasPrefix("gcm.")
    }
}

#if canImport(AppIntents)
import AppIntents
#endif
import Foundation
import TranthorPushService

final class NotificationService: TranthorNotificationServiceExtension {
    override var allowedImageHosts: Set<String> {
        // Configure exact publisher-controlled HTTPS CDN hosts in this extension's Info.plist.
        Set(Bundle.main.object(forInfoDictionaryKey: "TranthorAllowedImageHosts") as? [String] ?? [])
    }
    /// The App Group shared with the app, for `tranthor.badge == "increment"`. Empty (the default) leaves the badge alone.
    /// Set TranthorAppGroup in this extension's Info.plist and enable the same group on the app and the extension.
    override var appGroupIdentifier: String? {
        (Bundle.main.object(forInfoDictionaryKey: "TranthorAppGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

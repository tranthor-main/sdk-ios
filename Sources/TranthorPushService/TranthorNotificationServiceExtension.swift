import Foundation
import UserNotifications
import TranthorPushPayload

/// A Notification Service Extension that attaches remote images and applies the badge +1. Subclass it and override
/// `allowedImageHosts` (and `appGroupIdentifier` for the badge); nothing else is needed.
open class TranthorNotificationServiceExtension: UNNotificationServiceExtension {
    /// Host names images may be downloaded from, such as `images.example.com`. Without any, no image is shown.
    open var allowedImageHosts: Set<String> { [] }
    /// The App Group shared with the app, needed for `tranthor.badge == "increment"`. Nil leaves the badge alone.
    open var appGroupIdentifier: String? { nil }
    private let lock = NSLock()
    private var processor: TranthorRichPush?
    /// Applies the badge +1 and attaches the notification's image, then calls `contentHandler` exactly once.
    public final override func didReceive(_ request: UNNotificationRequest,
                                         withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        lock.lock()
        if processor == nil {
            processor = Self.makeProcessor(allowedHosts: allowedImageHosts,
                                           badgeCounter: appGroupIdentifier.flatMap { BadgeCounter(appGroupIdentifier: $0) })
        }
        let service = processor
        lock.unlock()
        if service?.didReceive(request, withContentHandler: contentHandler) != true { contentHandler(request.content) }
    }
    /// An invalid host entry (a URL or a port, say) must not cost the badge: the allow-list becomes empty, so no
    /// image is shown, and the badge still applies.
    static func makeProcessor(allowedHosts: Set<String>, badgeCounter: BadgeCounter?) -> TranthorRichPush {
        let configuration = (try? RichImageConfiguration(allowedHosts: allowedHosts)) ?? .noImages
        return TranthorRichPush(configuration: configuration, badgeCounter: badgeCounter)
    }
    /// Delivers the notification as it stands when the system is about to end the extension.
    public final override func serviceExtensionTimeWillExpire() {
        lock.lock(); let service = processor; lock.unlock()
        service?.serviceExtensionTimeWillExpire()
    }
}

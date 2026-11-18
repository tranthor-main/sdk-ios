import Foundation
import UserNotifications
import TranthorPushPayload

/// Image and badge handling for a Notification Service Extension that also hosts another SDK's handler.
public final class TranthorRichPush: Sendable {
    private let configuration: RichImageConfiguration
    private let load: @Sendable (URL, RichImageConfiguration) async throws -> URL
    private let badgeCounter: BadgeCounter?
    private let lock = NSLock()
    nonisolated(unsafe) private var active: [UUID: ImageCompletion] = [:] // All accesses under lock.
    /// Creates the handler. Pass `badgeAppGroup` to apply the badge +1.
    public convenience init(configuration: RichImageConfiguration, badgeAppGroup: String? = nil) {
        self.init(configuration: configuration, badgeCounter: badgeAppGroup.flatMap { BadgeCounter(appGroupIdentifier: $0) })
    }
    convenience init(configuration: RichImageConfiguration, badgeCounter: BadgeCounter?) {
        self.init(configuration: configuration, load: { url, configuration in
            let downloader = RichImageDownloader(configuration: configuration)
            do { let file = try await downloader.download(url); await downloader.shutdown(); return file }
            catch { await downloader.shutdown(); throw error }
        }, badgeCounter: badgeCounter)
    }
    init(configuration: RichImageConfiguration, load: @escaping @Sendable (URL, RichImageConfiguration) async throws -> URL,
         badgeCounter: BadgeCounter? = nil) {
        self.configuration = configuration; self.load = load; self.badgeCounter = badgeCounter
    }
    /// Handles a notification request. Returns false, without calling `handler`, when it is not a Tranthor push
    /// that needs work, so you can pass it to another handler. Otherwise returns true and calls `handler` once.
    public func didReceive(_ request: UNNotificationRequest,
                           withContentHandler handler: @escaping (UNNotificationContent) -> Void) -> Bool {
        guard let notification = PushNotification(userInfo: request.content.userInfo) else { return false }
        // Add one to the App Group count first, once per request, and carry the badged content through
        // every completion path (image success, failure, disallowed host, expiry).
        var content = request.content
        var badged = false
        if notification.incrementsBadge, let count = badgeCounter?.increment(),
           let modified = request.content.mutableCopy() as? UNMutableNotificationContent {
            modified.badge = NSNumber(value: count)
            content = modified; badged = true
        }
        guard notification.imageURL != nil || badged else { return false }
        let completion = ImageCompletion(content: content, handler: handler)
        guard let raw = notification.imageURL, raw.utf8.count <= 4096, let url = URL(string: raw), configuration.accepts(url) else {
            completion.finish(); return true
        }
        let id = UUID()
        lock.lock()
        guard active.count < 32 else { lock.unlock(); completion.finish(); return true }
        active[id] = completion
        lock.unlock()
        let load = self.load, configuration = self.configuration
        let work = Task {
            do { let file = try await load(url, configuration); completion.finish(image: file) }
            catch { completion.finish() }
            remove(id)
        }
        completion.installCancellation { work.cancel() }
        return true
    }
    /// Call from your extension's `serviceExtensionTimeWillExpire()`; delivers every pending notification now.
    public func serviceExtensionTimeWillExpire() {
        lock.lock(); let pending = Array(active.values); active.removeAll(); lock.unlock()
        for completion in pending { completion.finish() } // Synchronous, outside the registry lock.
    }
    private func remove(_ id: UUID) { lock.lock(); active.removeValue(forKey: id); lock.unlock() }
}

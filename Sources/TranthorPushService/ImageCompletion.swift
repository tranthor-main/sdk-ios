import Foundation
import UserNotifications

/// Objective-C supplies a non-Sendable callback/content pair. Every access is under the lock;
/// the winning finisher consumes the pair before unlocking.
final class ImageCompletion: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var content: UNNotificationContent?
    nonisolated(unsafe) private var handler: ((UNNotificationContent) -> Void)?
    nonisolated(unsafe) private var cancellation: (@Sendable () -> Void)?
    init(content: UNNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
        self.content = content; self.handler = handler
    }
    func installCancellation(_ cancel: @escaping @Sendable () -> Void) {
        lock.lock(); let finished = handler == nil
        if !finished { cancellation = cancel }
        lock.unlock()
        if finished { cancel() }
    }
    func finish(image: URL? = nil) {
        lock.lock(); let deliver = handler, original = content, cancel = cancellation
        handler = nil; content = nil; cancellation = nil; lock.unlock()
        cancel?()
        var keepAttachmentSource = false
        defer { if let image, !keepAttachmentSource { RichImageDownloader.remove(image) } }
        guard let deliver, let original else { return }
        if let image, let modified = original.mutableCopy() as? UNMutableNotificationContent,
           let attachment = try? UNNotificationAttachment(identifier: "tranthor-image", url: image, options: nil) {
            modified.attachments = original.attachments + [attachment]
            keepAttachmentSource = true // iOS may consume only after the completion returns.
            deliver(modified)
        } else { deliver(original) }
    }
}

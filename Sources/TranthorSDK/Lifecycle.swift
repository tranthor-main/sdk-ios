#if canImport(UIKit)
import UIKit

@MainActor
final class LifecycleObserver {
    private weak var sdk: TranthorSDK?
    private var tokens: [NSObjectProtocol] = []
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var taskToken: UUID?
    private var operation: Task<Void, Never>?
    private weak var application: UIApplication?

    init(sdk: TranthorSDK) {
        self.sdk = sdk
        // sharedApplication is unavailable to extensions. Selector lookup avoids referencing
        // that API in extension-safe binaries; extensions never install lifecycle observers.
        guard !Bundle.main.bundlePath.hasSuffix(".appex") else { return }
        application = UIApplication.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? UIApplication
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willResignActiveNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.backgrounded(pauseOnFailure: name == UIApplication.didEnterBackgroundNotification) }
            })
        }
        for name in [UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let sdk = self.sdk else { return }
                    self.finish(self.taskToken)
                    Task { await sdk.resumeOnForeground() }
                }
            })
        }
    }
    private func backgrounded(pauseOnFailure: Bool) {
        guard let sdk else { return }
        if operation != nil {
            if pauseOnFailure, let token = taskToken { Task { await sdk.enterBackground(token) } }
            return
        }
        let token = UUID()
        taskToken = token
        // Begin synchronously while UIKit is still delivering the background notification.
        if let application, application.delegate != nil {
            identifier = application.beginBackgroundTask(withName: "TranthorSDK flush") { [weak self] in
                guard let self, self.taskToken == token else { return }
                self.operation?.cancel()
                // State was persisted before sending. End synchronously; actor cleanup must
                // not consume the expired background window. The UUID rejects stale expiry.
                self.finish(token)
                Task { await sdk.expireBackground(token) }
            }
        }
        operation = Task { [weak self] in
            if pauseOnFailure { await sdk.flushForBackground(token) }
            else { await sdk.flushForInactivity(token) }
            self?.finish(token)
        }
    }
    private func finish(_ token: UUID?) {
        guard let token, taskToken == token else { return }
        if identifier != .invalid { application?.endBackgroundTask(identifier) }
        identifier = .invalid
        taskToken = nil
        operation = nil
    }
    func dispose() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
        operation?.cancel()
        finish(taskToken)
        sdk = nil
    }
}
#endif

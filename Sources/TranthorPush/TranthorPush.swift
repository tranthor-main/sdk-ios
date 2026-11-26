import Foundation
import TranthorSDK
import UserNotifications

/// Native push for an app that already uses ``TranthorSDK``. It registers the device with the SDK while a
/// customer is signed in and reports push interactions through the SDK's event queue. It owns neither
/// `UIApplication` nor the notification delegate, never swizzles, and never asks for permission.
public actor TranthorPush {
    /// The configuration this instance was created with.
    public nonisolated let configuration: PushConfiguration
    private let sdk: TranthorSDK
    private let permission: @Sendable () async -> InstallationPermission
    private let categoryStore: (any NotificationCategoryStore)?
    private var token: String?
    private var stopped = false
    private var installationTail: Task<Void, Never>?
    private var registeringCategory = false
    private var categoryRecheck = false
    #if canImport(UIKit)
    private var foreground: ForegroundObserver?
    #endif
    private struct EventKey: Hashable { let id: String; let interaction: PushInteraction }
    private var pending: Set<EventKey> = []
    private var recent: Set<EventKey> = []
    private var recentOrder: [EventKey] = []

    /// Binds push to `sdk`: the SDK sends `Installation Registered` and `Installation Removed` and reports
    /// `Push Received`, `Push Opened` and `Push Dismissed` under its own identity and consent. `identify`,
    /// `reset`, `optOut` and `optIn` on the SDK keep the registration in step. Registers the `TRANTHOR_PUSH`
    /// category next to your own; register your categories before creating this instance. Retain the instance.
    ///
    /// If the workspace requires verified identity, register push only after sign-in: call
    /// ``TranthorSDK/identify(userId:identityToken:anonymousId:traits:messageId:timestamp:context:)`` first. The server drops an
    /// anonymous registration and anonymous push interaction events without an error; the SDK reports the count through
    /// ``TranthorSDK/Configuration/onNotice``.
    ///
    /// - Throws: ``PushError/invalidBundleIdentifier`` when the configuration's bundle identifier is malformed.
    public init(configuration: PushConfiguration, sdk: TranthorSDK) async throws {
        try await self.init(configuration: configuration, sdk: sdk, permission: { await PushAuthorization.currentState() },
                            categoryStore: LiveCategoryStore())
    }
    init(configuration: PushConfiguration, sdk: TranthorSDK,
         permission: @escaping @Sendable () async -> InstallationPermission = { await PushAuthorization.currentState() },
         categoryStore: (any NotificationCategoryStore)?) async throws {
        let id = configuration.bundleIdentifier
        let labels = id.split(separator: ".", omittingEmptySubsequences: false)
        guard id.utf8.count <= 255, labels.count >= 2, !labels.contains(""),
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else {
            throw PushError.invalidBundleIdentifier
        }
        self.configuration = configuration; self.sdk = sdk
        self.permission = permission; self.categoryStore = categoryStore
        // iOS reports a dismissal only for a notification whose category is registered.
        if categoryStore != nil { await registerNotificationCategory() }
        #if canImport(UIKit)
        foreground = ForegroundObserver { [weak self] in await self?.appDidBecomeActive() }
        #endif
    }

    /// Registers the `TRANTHOR_PUSH` category so iOS reports a dismissal of a Tranthor push, keeping the categories
    /// already registered. A category with that identifier that you registered yourself is left alone.
    /// Called at start and whenever the app becomes active; call it after replacing the category set with
    /// `setNotificationCategories`. Does nothing after ``shutdown()``.
    public func registerNotificationCategory() async {
        guard !stopped else { return }
        let store = categoryStore ?? LiveCategoryStore()
        if registeringCategory { categoryRecheck = true; return }
        registeringCategory = true
        defer { registeringCategory = false; categoryRecheck = false }
        // The host can replace the whole set between our read and write, so re-read after each write and merge
        // again, within a fixed number of passes.
        var seen: [String: UNNotificationCategory] = [:]
        var writes = 0, passes = 0
        while passes < Self.categoryPassLimit {
            passes += 1
            let current = await store.categories().categories
            for category in current where seen[category.identifier] == nil { seen[category.identifier] = category }
            // The current set, plus any category seen before that has gone, plus ours unless the host registered its own.
            var desired = current
            let present = Set(current.map(\.identifier))
            for (identifier, category) in seen where !present.contains(identifier) { desired.insert(category) }
            if let merged = PushCategory.merged(into: desired) { desired = merged }
            if desired.count == current.count {
                // Nothing to add. A call that arrived meanwhile gets one more look.
                if categoryRecheck { categoryRecheck = false; continue }
                return
            }
            guard writes < Self.categoryWriteLimit else { return }
            await store.replace(with: CategorySnapshot(categories: desired))
            writes += 1
        }
    }
    static let categoryWriteLimit = 3
    static let categoryPassLimit = 6

    /// Reads the notification permission again and registers the token again if it changed. Call it after a
    /// permission request. Does nothing before a token arrives or after ``shutdown()``.
    public func refreshPermission() async throws {
        guard !stopped, token != nil else { return }
        try await registerInstallationInOrder()
    }
    func appDidBecomeActive() async {
        guard !stopped else { return }
        try? await refreshPermission()
        if categoryStore != nil { await registerNotificationCategory() }
    }
    /// Reads the permission and hands the token to the SDK, one registration at a time in call order, using the
    /// token current when its turn comes. Otherwise a slow `permission()` could finish after a later call and
    /// make the older reading the last word.
    private func registerInstallationInOrder() async throws {
        let previous = installationTail
        let current = Task<Result<Void, any Error>, Never> {
            await previous?.value
            do { try await self.registerInstallationNow(); return .success(()) } catch { return .failure(error) }
        }
        installationTail = Task { _ = await current.value }
        try await current.value.get()
    }
    private func registerInstallationNow() async throws {
        guard !stopped, let token else { return }
        let environment: InstallationEnvironment = switch configuration.environment {
        case .development: .development
        case .production: .production
        }
        try await sdk.registerInstallation(token: token, appId: configuration.bundleIdentifier, environment: environment,
                                           permission: await permission())
    }

    /// Hands over the APNs device token. Call it from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
    /// on every launch. It is registered once a customer is signed in, which is also what a workspace that requires
    /// verified identity needs: an anonymous registration would be dropped by the server.
    public func registerDeviceToken(_ data: Data) async throws {
        guard !stopped else { throw PushError.shutDown }
        guard !data.isEmpty else { throw PushError.emptyDeviceToken }
        token = data.map { String(format: "%02x", $0) }.joined()
        try await registerInstallationInOrder()
    }
    /// Stops this instance: it forgets the token, ignores later notifications and no longer re-registers the
    /// category when the app becomes active. The SDK's own state is untouched.
    public func shutdown() {
        stopped = true; token = nil
        #if canImport(UIKit)
        foreground = nil
        #endif
    }

    /// Reports a notification interaction to the SDK. Call it from your `UNUserNotificationCenterDelegate` with
    /// `PushNotification(userInfo:)`. Returns false for a payload that is not a Tranthor push. The system
    /// completion handler stays yours. Duplicate interactions are reported once.
    @discardableResult
    public func handle(_ notification: PushNotification?, interaction: PushInteraction) async throws -> Bool {
        guard let notification else { return false }
        // Identity and consent are read once, at admission, from the SDK.
        let user = await sdk.userId, anonymous = await sdk.anonymousId
        guard !stopped, !(await sdk.isOptedOut) else { return true }
        let key = EventKey(id: notification.deliveryID, interaction: interaction)
        guard !pending.contains(key), !recent.contains(key) else { return true }
        // Also bound suspended handlers; drop observation rather than grow without limit.
        guard pending.count < configuration.recentEventLimit else { return true }
        pending.insert(key)
        defer { pending.remove(key) }
        let event = PushEvent(deliveryID: notification.deliveryID, interaction: interaction)
        let name: String
        switch interaction {
        case .foreground: name = "Push Received"
        case .opened: name = "Push Opened"
        case .dismissed: name = "Push Dismissed"
        }
        // Only the delivery ID: the server counts a claim by it and nothing else is needed.
        let properties: [String: JSONValue] = ["deliveryId": .string(event.deliveryID)]
        if let user { try await sdk.track(event: name, userId: user, properties: properties, messageId: event.messageId) }
        else { try await sdk.track(event: name, anonymousId: anonymous, properties: properties, messageId: event.messageId) }
        try await configuration.onEvent(event)
        recent.insert(key); recentOrder.append(key)
        if recentOrder.count > configuration.recentEventLimit {
            recent.remove(recentOrder.removeFirst())
        }
        return true
    }
}

#if canImport(UIKit)
import UIKit
/// Calls `onActive` each time the app becomes active, so a permission changed in Settings is noticed. Never calls UIApplication.
private final class ForegroundObserver: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ onActive: @escaping @Sendable () async -> Void) {
        token = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            Task { await onActive() }
        }
    }
    deinit { NotificationCenter.default.removeObserver(token) }
}
#endif

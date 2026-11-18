import Foundation
import SwiftUI
import UserNotifications
import TranthorSDK
import TranthorPush

/// One per app launch, retained before delegate callbacks arrive. No token is persisted or logged.
@MainActor
final class ExamplePushModel: ObservableObject {
    static let shared = ExamplePushModel()
    @Published private(set) var authorization = "Not requested"
    @Published private(set) var registration = "No APNs token registered yet"
    @Published private(set) var categoryStatus = "Dismiss category not registered yet"
    @Published private(set) var tokenStatus = "No APNs token received"
    @Published private(set) var observations = 0
    @Published private(set) var lastObservation = "None"
    @Published private(set) var enabled = false
    @Published private(set) var previewDeliveryId = "None"
    var onEvent: (@MainActor @Sendable (PushEvent) async throws -> Void)?
    var onLog: (@MainActor @Sendable (String) -> Void)?
    private var client: TranthorPush?
    private var boundSDK: TranthorSDK?
    private var launchToken: Data?
    private var pendingLaunchObservations: [(PushNotification, PushInteraction)] = []
    private let bundleIdentifier: String?
    let environment: APNsEnvironment
    let hasConfiguredEnvironment: Bool
    /// Creates the `TranthorPush` bound to the SDK. Tests replace it, because the live one needs an app bundle.
    typealias Factory = @Sendable (PushConfiguration, TranthorSDK) async throws -> TranthorPush
    private let factory: Factory?

    init(bundleIdentifier: String? = Bundle.main.bundleIdentifier,
         environment: APNsEnvironment? = (Bundle.main.object(forInfoDictionaryKey: "TranthorAPNsEnvironment") as? String).flatMap(APNsEnvironment.init(rawValue:)),
         factory: Factory? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.environment = environment ?? .development // Unsigned local preview only.
        hasConfiguredEnvironment = environment != nil
        self.factory = factory
    }

    /// Binds TranthorPush to `sdk` once: the SDK registers the Installation and reports pushes through its queue,
    /// under its own identity and consent. Without an SDK (test doubles) there is nothing to bind.
    func synchronize(optedOut: Bool, sdk: TranthorSDK? = nil) async {
        enabled = !optedOut
        guard let sdk else { return drainLaunchObservations(optedOut: optedOut) }
        do {
            if boundSDK !== sdk {
                guard let bundle = bundleIdentifier else { throw PushError.invalidBundleIdentifier }
                boundSDK = sdk
                let configuration = PushConfiguration(bundleIdentifier: bundle, environment: environment,
                    onEvent: { [weak self] event in
                        guard let self else { return }
                        try await self.record(event)
                    })
                if let factory {
                    client = try await factory(configuration, sdk)
                } else {
                    // The host registers its own category first; the SDK merges TRANTHOR_PUSH into the set.
                    UNUserNotificationCenter.current().setNotificationCategories([
                        UNNotificationCategory(identifier: "EXAMPLE_HOST_CATEGORY", actions: [], intentIdentifiers: [], options: [])])
                    client = try await TranthorPush(configuration: configuration, sdk: sdk)
                    await refreshCategoryStatus()
                }
                registration = "Installation is registered through the SDK queue once an APNs token arrives"
            }
            if let client, let token = launchToken { launchToken = nil; try await client.registerDeviceToken(token); registration = "Installation Registered queued" }
        } catch { registration = "APNs token could not be registered" }
        drainLaunchObservations(optedOut: optedOut)
    }
    private func refreshCategoryStatus() async {
        let registered = await withCheckedContinuation { (continuation: CheckedContinuation<[(String, Bool)], Never>) in
            UNUserNotificationCenter.current().getNotificationCategories {
                continuation.resume(returning: $0.map { ($0.identifier, $0.options.contains(.customDismissAction)) })
            }
        }
        let dismiss = registered.first { $0.0 == PushCategory.identifier }?.1 == true
        let host = registered.contains { $0.0 == "EXAMPLE_HOST_CATEGORY" }
        categoryStatus = dismiss ? "TRANTHOR_PUSH registered with customDismissAction" + (host ? "; host category kept" : "; host category LOST")
                                 : "TRANTHOR_PUSH not registered"
    }
    private func drainLaunchObservations(optedOut: Bool) {
        let pending = pendingLaunchObservations
        pendingLaunchObservations.removeAll()
        if !optedOut {
            // Configure/refresh may hold the model's mutation gate. Do not await event
            // admission here: drain after refresh returns, under its normal consent guard.
            Task { for (payload, interaction) in pending { await self.receive(payload, interaction: interaction) } }
        }
    }
    func disable() async {
        enabled = false
        if client != nil { pendingLaunchObservations.removeAll() }
    }
    func receiveToken(_ data: Data) async {
        tokenStatus = "APNs token received (hidden)"
        guard let client else { launchToken = data; return }
        do { try await client.registerDeviceToken(data); registration = "Installation Registered queued through the SDK" }
        catch { registration = "APNs token could not be registered" }
    }
    func registrationFailed() {
        tokenStatus = "APNs registration failed"
        onLog?("APNs registration failed. Check Push Notifications entitlement, signing and account. No token was logged.")
    }
    func requestPermission() async {
        do {
            authorization = try await PushAuthorization.request() ? "Authorized" : "Denied — change in Settings"
        } catch { authorization = "Permission request failed" }
    }
    func preview(withImage: Bool = false) async {
        await requestPermission()
        guard authorization == "Authorized" else { return }
        let content = UNMutableNotificationContent()
        let deliveryId = "preview-\(UUID().uuidString)"
        content.title = "Tranthor push preview \(deliveryId.suffix(8))"
        content.body = "Local notification: tap to test the opened event. Real APNs delivery needs a paid Apple Developer account."
        content.sound = .default
        // Like the server's payload: the registered category makes iOS report an explicit dismissal.
        content.categoryIdentifier = PushCategory.identifier
        content.userInfo = ["tranthor": ["version": 1, "deliveryId": deliveryId]]
        var attachmentSource: URL?
        if withImage {
            guard let bundled = Bundle.main.url(forResource: "preview-image", withExtension: "png") else {
                onLog?("Bundled preview image missing; rebuild the latest example app."); return
            }
            do {
                // iOS takes ownership of an attachment file, so attach a copy.
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("example-preview-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let copy = directory.appendingPathComponent("preview-image.png")
                try FileManager.default.copyItem(at: bundled, to: copy)
                attachmentSource = copy
                content.attachments = [try UNNotificationAttachment(identifier: "preview-image", url: copy, options: nil)]
            } catch {
                removeAttachmentSource(attachmentSource)
                onLog?("Could not attach preview image."); return
            }
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: ProcessInfo.processInfo.arguments.contains("--ui-testing") ? 6 : 2, repeats: false))
        do {
            try await UNUserNotificationCenter.current().add(request)
            previewDeliveryId = deliveryId
            onLog?("Local push preview scheduled. It does not contact APNs.")
        } catch {
            removeAttachmentSource(attachmentSource)
            onLog?("Could not schedule the local push preview.")
        }
    }
    private func removeAttachmentSource(_ file: URL?) {
        if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    }
    /// Invoked after the host completes the system callback. Presentation remains host-owned.
    func receive(_ payload: PushNotification?, interaction: PushInteraction) async {
        guard let payload else { return }
        guard let client else {
            pendingLaunchObservations.append((payload, interaction))
            if pendingLaunchObservations.count > 32 { pendingLaunchObservations.removeFirst() }
            return
        }
        guard enabled else { return }
        do { _ = try await client.handle(payload, interaction: interaction) }
        catch { onLog?("Push observation could not be admitted to the events SDK.") }
    }
    private func record(_ event: PushEvent) async throws {
        guard enabled, let onEvent else { return }
        try await onEvent(event)
        observations += 1
        switch event.interaction {
        case .foreground: lastObservation = "Foreground notification observed"
        case .opened: lastObservation = "Notification opened"
        case .dismissed: lastObservation = "Notification dismissed"
        }
        onLog?(lastObservation + "; tagged event accepted locally.")
    }
}

import Foundation

/// Registers the app's push Installation through the durable event queue.
extension TranthorSDK {
    /// What the host's `onError` receives: `Installation Registered/Removed` events without the push token
    /// (`"<redacted>"`), so a host that logs a `BatchFailure` does not log device tokens. Only this copy changes: the
    /// events queued, persisted and sent to the server keep the real token. Every other event is passed on untouched.
    static func redactingToken(_ events: [[String: JSONValue]]) -> [[String: JSONValue]] {
        events.map { item in
            guard installationTarget(item) != nil, var properties = item["properties"]?.object, properties["token"] != nil else { return item }
            properties["token"] = .string("<redacted>")
            var copy = item
            copy["properties"] = .object(properties)
            return copy
        }
    }
    static func installationTarget(_ item: [String: JSONValue]) -> String? {
        guard let event = item["event"]?.string, event == "Installation Registered" || event == "Installation Removed" else { return nil }
        let properties = item["properties"]?.object
        return "\(properties?["appId"]?.string ?? "")|\(properties?["token"]?.string ?? "")"
    }
    /// Binds this app install's APNs `token` to the signed-in customer by queueing an
    /// `Installation Registered` event through the durable queue. A different token, app ID or environment
    /// first queues `Installation Removed` for the old one. The same binding is sent once per app start, again
    /// when the owner, permission or app/OS/SDK version changes. While opted out nothing is queued: the latest
    /// binding is kept and `optIn()` registers it. While nobody is signed in nothing is queued either: the token is
    /// held and `identify` registers it. Empty `token` or `appId` is ignored. The token is never logged.
    package func registerInstallation(token: String, appId: String, environment: InstallationEnvironment,
                                     permission: InstallationPermission) throws {
        guard !stopped, !token.isEmpty, !appId.isEmpty else { return }
        let previous = state.installation
        let next = StoredInstallation(token: token, appId: appId, environment: environment.rawValue, permission: permission.rawValue)
        // A phone is registered only to an identified customer: until identify() the token is held, not sent.
        if state.optedOut || state.userId == nil {
            state.installation = next; sentInstallation = nil
            do { try store.save(state) } catch { state.installation = previous; throw error }
            return
        }
        var items: [[String: JSONValue]] = []
        if let previous, previous.token != next.token || previous.appId != next.appId || previous.environment != next.environment {
            items.append(installationItem("Installation Removed", previous, details: false))
        }
        let fingerprint = installationFingerprint(next)
        if items.isEmpty && fingerprint == sentInstallation { return }
        items.append(installationItem("Installation Registered", next, details: true))
        state.installation = next
        do { try admit(items) } catch { state.installation = previous; throw error }
        sentInstallation = fingerprint
    }
    func installationFingerprint(_ installation: StoredInstallation) -> [String] {
        [installation.token, installation.appId, installation.environment,
         state.userId.map { "user:\($0)" } ?? "anonymous:\(state.anonymousId)", installation.permission,
         installationAppVersion(), installationOSVersion(), TranthorSDKVersion.current]
    }
    /// Strictly increasing within the process, so a Registered never ties with the Removed before it.
    func nextInstallationTime() -> String {
        let now = max(Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)), installationClockMs &+ 1)
        installationClockMs = now
        // Centre in the millisecond so floating point cannot print the previous one.
        return timestamp(Date(timeIntervalSince1970: (Double(now) + 0.5) / 1000))
    }
    /// A track item for the server's Installation contract. `details` adds the fields that
    /// only a registration carries. The removal an opt-out leaves carries no automatic context.
    func installationItem(_ event: String, _ installation: StoredInstallation, details: Bool, context: Bool = true) -> [String: JSONValue] {
        var data = payload(userId: nil, anonymousId: nil, messageId: nil, timestamp: nextInstallationTime(), context: nil)
        if !context { data.removeValue(forKey: "context") }
        data["type"] = .string("track")
        data["event"] = .string(event)
        var properties: [String: JSONValue] = ["platform": .string("ios"), "appId": .string(installation.appId),
                                               "environment": .string(installation.environment), "token": .string(installation.token)]
        if details {
            properties["permissionState"] = .string(installation.permission)
            let app = installationAppVersion()
            if !app.isEmpty { properties["appVersion"] = .string(app) }
            properties["osVersion"] = .string(installationOSVersion())
            properties["sdkVersion"] = .string(TranthorSDKVersion.current)
        }
        data["properties"] = .object(properties)
        return data
    }

    /// One removal per token: the current Installation's, and every earlier undelivered one reissued with a new
    /// messageId and time (a registration admitted since may have reached the server, which keeps a token's
    /// latest event by time and drops a messageId it has already seen).
    func optOutRemovals() -> [[String: JSONValue]] {
        let current = state.installation.map { "\($0.appId)|\($0.token)" }
        var removals = state.pendingRemovals
            .filter { current == nil || Self.installationTarget($0) != current }
            .map { earlier -> [String: JSONValue] in
                var item = earlier
                item["messageId"] = .string(UUID().uuidString)
                item["timestamp"] = .string(nextInstallationTime())
                return item
            }
        // Only a signed-in customer's phone was registered.
        if let installation = state.installation, state.userId != nil {
            removals.append(installationItem("Installation Removed", installation, details: false, context: false))
        }
        return removals
    }
}

/// The `Installation Removed` an opt-out leaves, for the identity in `state`; no automatic context.
func optOutRemovalItem(_ state: StoredState, _ installation: StoredInstallation) -> [String: JSONValue] {
    var item: [String: JSONValue] = [
        "type": .string("track"), "event": .string("Installation Removed"),
        "messageId": .string(UUID().uuidString), "timestamp": .string(timestamp()),
        "properties": .object(["platform": .string("ios"), "appId": .string(installation.appId),
                               "environment": .string(installation.environment), "token": .string(installation.token)])]
    if let user = state.userId { item["userId"] = .string(user) } else { item["anonymousId"] = .string(state.anonymousId) }
    return item
}

import Foundation
import TranthorSDK
import TranthorPush

struct ExampleIdentity: Sendable {
    let anonymousId: String
    let userId: String?
    let optedOut: Bool
}

enum ExampleEvent: Sendable { case track, page, screen }

/// Private example seam: tests can suspend lifecycle operations without changing SDK API.
@MainActor
protocol ExampleClient: AnyObject {
    func identity() async -> ExampleIdentity
    func identify(userId: String, tags: [String: JSONValue]) async throws
    func send(_ event: ExampleEvent, tags: [String: JSONValue]) async throws
    /// The SDK a bound TranthorPush sends its Installation and Push events through; nil for test doubles.
    var tranthor: TranthorSDK? { get }
    func flush() async throws
    func optOut() async throws
    func optIn() async throws
    func reset() async throws
    func shutdown() async
}

extension ExampleClient {
    var tranthor: TranthorSDK? { nil }
}

@MainActor
private final class LiveExampleClient: ExampleClient {
    let sdk: TranthorSDK
    init(_ sdk: TranthorSDK) { self.sdk = sdk }
    func identity() async -> ExampleIdentity {
        ExampleIdentity(anonymousId: await sdk.anonymousId, userId: await sdk.userId, optedOut: await sdk.isOptedOut)
    }
    func identify(userId: String, tags: [String: JSONValue]) async throws {
        // identify accepts traits and context, not properties.
        try await sdk.identify(userId: userId, traits: tags, context: tags)
    }
    func send(_ event: ExampleEvent, tags: [String: JSONValue]) async throws {
        switch event {
        case .track: try await sdk.track(event: "iOS Example Tagged Event", properties: tags)
        case .page: try await sdk.page(name: "iOS Example", properties: tags)
        case .screen: try await sdk.screen(name: "Example Home", properties: tags)
        }
    }
    func flush() async throws { try await sdk.flush() }
    var tranthor: TranthorSDK? { sdk }
    func optOut() async throws { try await sdk.optOut() }
    func optIn() async throws { try await sdk.optIn() }
    func reset() async throws { try await sdk.reset() }
    func shutdown() async { await sdk.shutdown() }
}

@MainActor
struct ExampleServices {
    var makeClient: @MainActor (Configuration) async throws -> any ExampleClient
    var readKey: () throws -> String?
    var saveKey: (String) throws -> Void
    var readHost: () -> String?
    var saveHost: (String) -> Void
    var monitorsNetwork = true
    var deleteKey: () throws -> Void = {}
    var readSlowFlush: () -> Bool = { false }
    var saveSlowFlush: (Bool) -> Void = { _ in }

    static var live: ExampleServices {
        ExampleServices(makeClient: { LiveExampleClient(try await TranthorSDK.configure($0)) },
                        readKey: { try Keychain.read() }, saveKey: { try Keychain.write($0) },
                        readHost: { UserDefaults.standard.string(forKey: "example.host") },
                        saveHost: { UserDefaults.standard.set($0, forKey: "example.host") },
                        deleteKey: { try Keychain.delete() },
                        readSlowFlush: { UserDefaults.standard.bool(forKey: "example.slowFlush") },
                        saveSlowFlush: { UserDefaults.standard.set($0, forKey: "example.slowFlush") })
    }
}

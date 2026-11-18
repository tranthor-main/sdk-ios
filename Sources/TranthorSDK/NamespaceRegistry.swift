import Foundation

/// Errors thrown by `TranthorSDK.configure(_:)`.
public enum TranthorError: Error, Sendable, Equatable {
    /// `Configuration.host` is not an `http` or `https` URL with a host name.
    case invalidHost
    /// Another instance in this process already uses the same `storageNamespace` and `storageDirectory`.
    case namespaceInUse
    /// Local store I/O failed; retry configuration later. The underlying error preserves diagnostics.
    case storeTemporarilyUnavailable(underlying: any Error)

    /// Two errors are equal when they are the same case; stored-store errors compare by domain and code.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.invalidHost, .invalidHost), (.namespaceInUse, .namespaceInUse): true
        case let (.storeTemporarilyUnavailable(a), .storeTemporarilyUnavailable(b)):
            (a as NSError).domain == (b as NSError).domain && (a as NSError).code == (b as NSError).code
        default: false
        }
    }
}

/// A process-wide lease prevents two actors from overwriting the same store.
actor NamespaceRegistry {
    static let shared = NamespaceRegistry()
    private var leases: [String: UUID] = [:]
    func acquire(directory: URL?, namespace: String) throws -> NamespaceLease {
        let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("TranthorSDK", isDirectory: true)
        let base = (directory ?? defaultDirectory)?.standardizedFileURL.resolvingSymlinksInPath().path ?? "application-support"
        let key = base + "\u{0}" + namespace
        guard leases[key] == nil else { throw TranthorError.namespaceInUse }
        let token = UUID()
        leases[key] = token
        return NamespaceLease(key: key, token: token)
    }
    func release(_ lease: NamespaceLease) {
        if leases[lease.key] == lease.token { leases[lease.key] = nil }
    }
}
struct NamespaceLease: Sendable {
    let key: String
    let token: UUID
}

extension TranthorError: LocalizedError {
    /// A readable description of the error.
    public var errorDescription: String? {
        switch self {
        case .invalidHost: "The SDK host must be an http or https URL."
        case .namespaceInUse: "The SDK storage namespace is already in use."
        case .storeTemporarilyUnavailable: "The SDK store is temporarily unavailable. Retry configuration when storage is available."
        }
    }
}

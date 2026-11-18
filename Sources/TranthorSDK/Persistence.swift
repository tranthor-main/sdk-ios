import Foundation
import CryptoKit

struct StoredState: Codable, Sendable {
    static let currentVersion = 1
    let version = currentVersion
    var anonymousId = UUID().uuidString
    var userId: String?
    var optedOut = false
    var queued: [[String: JSONValue]] = []
    var active: [[String: JSONValue]] = []
    /// The push Installation last registered, so a token change, reset or opt-out can remove it.
    /// The token is therefore on disk (and in queued events until delivered): private storage, excluded from backup.
    var installation: StoredInstallation?
    /// `Installation Removed` events an opt-out still has to deliver. Delivered even while opted out.
    var pendingRemovals: [[String: JSONValue]] = []

    init() {}

    private enum CodingKeys: String, CodingKey { case version, anonymousId, userId, optedOut, queued, active, installation, pendingRemovals }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported state version")
        }
        // A missing identity is damage, not a default.
        anonymousId = try values.decode(String.self, forKey: .anonymousId)
        guard UUID(uuidString: anonymousId) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .anonymousId, in: values, debugDescription: "Invalid anonymous identity")
        }
        userId = try values.decodeIfPresent(String.self, forKey: .userId)
        optedOut = try values.decodeIfPresent(Bool.self, forKey: .optedOut) ?? false
        queued = try values.decodeIfPresent([[String: JSONValue]].self, forKey: .queued) ?? []
        active = try values.decodeIfPresent([[String: JSONValue]].self, forKey: .active) ?? []
        // Damage to these optional fields must not cost the identity or the queue.
        installation = try? values.decodeIfPresent(StoredInstallation.self, forKey: .installation)
        pendingRemovals = (try? values.decodeIfPresent([[String: JSONValue]].self, forKey: .pendingRemovals)) ?? []
    }
}

struct StoredInstallation: Codable, Sendable, Equatable {
    var token: String
    var appId: String
    var environment: String
    var permission: String
}

struct JSONStore: Sendable {
    let url: URL
    let consentURL: URL
    let corruptURL: URL
    private var ownsVerifiedFile: Bool
    /// The last `load()` found state saying opted in but consent saying opted out: an `optOut()` that wrote
    /// consent and was interrupted before its state write. Read it before the first `save`, which hides it.
    private(set) var interruptedOptOut = false
    private let writeData: @Sendable (Data, URL) throws -> Void
    private let read: @Sendable (URL) throws -> Data
    private let move: @Sendable (URL, URL) throws -> Void
    init(directory: URL?, namespace: String,
         write: @escaping @Sendable (Data, URL) throws -> Void = { try JSONStore.write($0, to: $1) },
         read: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
         move: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws {
        let base = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("TranthorSDK", isDirectory: true)
        // A digest keeps the folder name bounded and filesystem-safe for any namespace.
        let digest = SHA256.hash(data: Data(namespace.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = base.appendingPathComponent("sha256-" + digest, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.protect(folder)
        url = folder.appendingPathComponent("state.json")
        consentURL = folder.appendingPathComponent("consent.json")
        corruptURL = folder.appendingPathComponent("state.corrupt.json")
        ownsVerifiedFile = !FileManager.default.fileExists(atPath: url.path)
        writeData = write
        self.read = read
        self.move = move
    }
    mutating func load() throws -> StoredState {
        ownsVerifiedFile = false
        // Read both files before making any repairs. A transient I/O failure is not corruption.
        let stateData = try readIfPresent(url)
        let consentData = try readIfPresent(consentURL)
        let consent = consentData.flatMap { try? JSONDecoder().decode(Consent.self, from: $0) }
        var state = StoredState()
        var unsupportedStateVersion = false
        var decodedOptedIn = false
        interruptedOptOut = false
        if let data = stateData {
            if let decoded = try? JSONDecoder().decode(StoredState.self, from: data) {
                state = decoded
                decodedOptedIn = !decoded.optedOut
            } else {
                if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let version = object["version"] as? Int, version > StoredState.currentVersion {
                    unsupportedStateVersion = true
                }
                state = salvageIdentity(data)
                try quarantine(url, to: corruptURL)
            }
        }
        if consentData != nil && consent == nil {
            try quarantine(consentURL, to: consentURL.deletingLastPathComponent().appendingPathComponent("consent.corrupt.json"))
        }
        // A consent-only file is a valid crash residue from first-run consent -> state writes.
        // Verified consent wins over damaged supported state; future versions fail closed.
        if unsupportedStateVersion { state.optedOut = true }
        else if let consent {
            // Consent is written before state: "in" in state and "out" in consent is an interrupted opt-out.
            interruptedOptOut = decodedOptedIn && consent.optedOut
            state.optedOut = consent.optedOut
        }
        else if stateData != nil || consentData != nil || FileManager.default.fileExists(atPath: corruptURL.path)
            || FileManager.default.fileExists(atPath: consentURL.deletingLastPathComponent().appendingPathComponent("consent.corrupt.json").path) {
            state.optedOut = true
        }
        ownsVerifiedFile = true
        return state
    }
    private func readIfPresent(_ url: URL) throws -> Data? {
        do { return try read(url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        catch { throw TranthorError.storeTemporarilyUnavailable(underlying: error) }
    }
    private func quarantine(_ original: URL, to destination: URL) throws {
        do {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try move(original, destination)
            try Self.protect(destination)
        } catch {
            // load never grants write ownership if the move fails. configure must stop here.
            throw TranthorError.storeTemporarilyUnavailable(underlying: error)
        }
    }
    func save(_ state: StoredState) throws {
        // The namespace lease guarantees one writer; load verifies/quarantines once.
        guard ownsVerifiedFile else { throw TranthorError.storeTemporarilyUnavailable(underlying: CocoaError(.fileWriteNoPermission)) }
        try writeData(JSONEncoder().encode(state), url)
    }
    /// Consent is deliberately separate: routine queue/identity saves cannot reopen consent.
    func saveConsent(_ optedOut: Bool) throws {
        try writeData(JSONEncoder().encode(Consent(optedOut: optedOut)), consentURL)
    }
    private struct Consent: Codable {
        let version: Int
        let optedOut: Bool
        init(optedOut: Bool) { version = 1; self.optedOut = optedOut }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            guard version == 1 else {
                throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported consent version")
            }
            optedOut = try values.decode(Bool.self, forKey: .optedOut)
        }
    }
    private func salvageIdentity(_ data: Data) -> StoredState {
        var result = StoredState()
        // Salvage only a syntactically valid JSON object's independently valid identity fields.
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let anonymous = object["anonymousId"] as? String, UUID(uuidString: anonymous) != nil { result.anonymousId = anonymous }
            result.userId = object["userId"] as? String
        }
        return result
    }
    static func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try protect(url)
    }
    private static func protect(_ url: URL) throws {
        var location = url
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try location.setResourceValues(resources)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}

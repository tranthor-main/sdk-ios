import Foundation
import CryptoKit

/// One queued event and the number that orders it. The number only ever grows, so file dates are never read.
struct QueuedEvent: Sendable {
    let sequence: UInt64
    let event: [String: JSONValue]
}

/// What the state file holds. The queued events are not part of it: each is its own file in the queue folder.
struct StoredState: Codable, Sendable {
    static let currentVersion = 2
    let version = currentVersion
    var anonymousId = UUID().uuidString
    var userId: String?
    var optedOut = false
    /// The push Installation last registered, so a token change, reset or opt-out can remove it.
    /// The token is therefore on disk (and in queued events until delivered): private storage, excluded from backup.
    var installation: StoredInstallation?
    /// `Installation Removed` events an opt-out still has to deliver. Delivered even while opted out.
    var pendingRemovals: [[String: JSONValue]] = []
    /// The identity tokens of the users with events here, written with the state and so protected like the queue. Not the
    /// Keychain: a reinstall must not bring an old token back.
    var identityTokens = IdentityTokenCache()
    /// An identity token has been handed over through `identify`. Never cleared: it decides whether a refusal holds a batch.
    var identityTokenSupplied = false
    /// The sequence number from which queued events count when the current user is worked out after a restart: `reset()`
    /// moves it past the events it left behind, so the outgoing user does not become the current user again.
    var userEpochSequence: UInt64 = 0

    init() {}

    private enum CodingKeys: String, CodingKey { case version, anonymousId, userId, optedOut, installation, pendingRemovals, identityTokens, identityTokenSupplied, userEpochSequence }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard (1...Self.currentVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported state version")
        }
        // A missing identity is damage, not a default.
        anonymousId = try values.decode(String.self, forKey: .anonymousId)
        guard UUID(uuidString: anonymousId) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .anonymousId, in: values, debugDescription: "Invalid anonymous identity")
        }
        userId = try values.decodeIfPresent(String.self, forKey: .userId)
        optedOut = try values.decodeIfPresent(Bool.self, forKey: .optedOut) ?? false
        // Damage to these optional fields must not cost the identity or the queue.
        installation = try? values.decodeIfPresent(StoredInstallation.self, forKey: .installation)
        pendingRemovals = (try? values.decodeIfPresent([[String: JSONValue]].self, forKey: .pendingRemovals)) ?? []
        // A state written before identity tokens, or a damaged cache, starts with an empty one. The provider refills it.
        identityTokens = (try? values.decodeIfPresent(IdentityTokenCache.self, forKey: .identityTokens)) ?? IdentityTokenCache()
        // Damage to the flag alone must not turn identity off while tokens are cached.
        identityTokenSupplied = (try? values.decodeIfPresent(Bool.self, forKey: .identityTokenSupplied)) ?? !identityTokens.isEmpty
        userEpochSequence = (try? values.decodeIfPresent(UInt64.self, forKey: .userEpochSequence)) ?? 0
    }
}

/// The undelivered events in memory, oldest first.
struct EventQueue: Sendable {
    var events: [QueuedEvent] = []
    /// The number the next queued event gets.
    var nextSequence: UInt64 = 1
}

/// The events a version 1 state file still held (`active`, then `queued`). Read once so `load()` can move them to queue files.
private struct LegacyEvents: Decodable {
    let events: [[String: JSONValue]]
    private enum CodingKeys: String, CodingKey { case version, queued, active }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == 1 else { events = []; return }
        events = (try values.decodeIfPresent([[String: JSONValue]].self, forKey: .active) ?? [])
            + (try values.decodeIfPresent([[String: JSONValue]].self, forKey: .queued) ?? [])
    }
}

/// What `JSONStore.load()` found: the state file and the queue folder.
@dynamicMemberLookup
struct LoadedStore: Sendable {
    var state = StoredState()
    var queue = EventQueue()
    subscript<Value>(dynamicMember keyPath: WritableKeyPath<StoredState, Value>) -> Value {
        get { state[keyPath: keyPath] }
        set { state[keyPath: keyPath] = newValue }
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
    /// One file per queued event, named by its sequence number.
    let queueURL: URL
    private var ownsVerifiedFile: Bool
    /// The last `load()` found state saying opted in but consent saying opted out: an `optOut()` that wrote
    /// consent and was interrupted before its state write. Read it before the first `save`, which hides it.
    private(set) var interruptedOptOut = false
    private let writeData: @Sendable (Data, URL) throws -> Void
    private let read: @Sendable (URL) throws -> Data
    private let move: @Sendable (URL, URL) throws -> Void
    private let removeFile: @Sendable (URL) throws -> Void
    init(directory: URL?, namespace: String,
         write: @escaping @Sendable (Data, URL) throws -> Void = { try JSONStore.write($0, to: $1) },
         read: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
         move: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
         removeFile: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws {
        let base = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("TranthorSDK", isDirectory: true)
        // A digest keeps the folder name bounded and filesystem-safe for any namespace.
        let digest = SHA256.hash(data: Data(namespace.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = base.appendingPathComponent("sha256-" + digest, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.protect(folder)
        queueURL = folder.appendingPathComponent("queue", isDirectory: true)
        try FileManager.default.createDirectory(at: queueURL, withIntermediateDirectories: true)
        try Self.protect(queueURL)
        url = folder.appendingPathComponent("state.json")
        consentURL = folder.appendingPathComponent("consent.json")
        corruptURL = folder.appendingPathComponent("state.corrupt.json")
        ownsVerifiedFile = !FileManager.default.fileExists(atPath: url.path)
        writeData = write
        self.read = read
        self.move = move
        self.removeFile = removeFile
    }
    mutating func load() throws -> LoadedStore {
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
            if let decoded = Self.decodeState(data) {
                state = decoded.state
                decodedOptedIn = !decoded.state.optedOut
                try migrateLegacyEvents(decoded.legacy, state: state)
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
        let queue = try loadQueue()
        ownsVerifiedFile = true
        return LoadedStore(state: state, queue: queue)
    }
    private static func decodeState(_ data: Data) -> (state: StoredState, legacy: [[String: JSONValue]])? {
        guard let state = try? JSONDecoder().decode(StoredState.self, from: data),
              let legacy = try? JSONDecoder().decode(LegacyEvents.self, from: data) else { return nil }
        return (state, legacy.events)
    }
    /// Moves the events of a version 1 file into queue files, then rewrites the file without them. The file names
    /// come from each event's position, so a run that stopped between the two steps repeats the same writes and
    /// nothing is duplicated or lost.
    private func migrateLegacyEvents(_ events: [[String: JSONValue]], state: StoredState) throws {
        guard !events.isEmpty else { return }
        do {
            for (index, event) in events.enumerated() {
                try writeData(JSONEncoder().encode(event), eventURL(UInt64(index + 1)))
            }
            try writeData(JSONEncoder().encode(state), url)
        } catch {
            throw TranthorError.storeTemporarilyUnavailable(underlying: error)
        }
    }
    /// Event files are named by a zero-padded sequence number so that name order is sequence order.
    static let sequenceWidth = 20
    /// `json` for a queued event; `corrupt` for a file set aside because its bytes are not an event.
    static func eventFileName(_ sequence: UInt64, extension fileExtension: String = "json") -> String {
        String(format: "%0\(sequenceWidth)llu", sequence) + "." + fileExtension
    }
    /// The number at the start of a name, whatever follows it.
    private static func leadingSequence(_ name: String) -> UInt64? {
        name.count > sequenceWidth ? UInt64(name.prefix(sequenceWidth)) : nil
    }
    private func eventURL(_ sequence: UInt64) -> URL {
        queueURL.appendingPathComponent(Self.eventFileName(sequence))
    }
    /// The queued events in order, by the number in each file name. A file that cannot be read stops loading: it is
    /// not damage, and the queue must not be reordered or renamed around it.
    private func loadQueue() throws -> EventQueue {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: queueURL.path) }
        catch { throw TranthorError.storeTemporarilyUnavailable(underlying: error) }
        var events: [QueuedEvent] = []
        var highest: UInt64 = 0
        for name in names {
            guard let sequence = Self.leadingSequence(name) else { continue }
            // A set-aside file still counts, so its number is never given to a new event.
            highest = max(highest, sequence)
            guard name == Self.eventFileName(sequence) else { continue }
            let file = queueURL.appendingPathComponent(name)
            guard let data = try readIfPresent(file) else { continue }
            if let event = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
                events.append(QueuedEvent(sequence: sequence, event: event))
            } else {
                // Its bytes were read but are not an event: keep them for inspection and carry on with the rest.
                try quarantine(file, to: queueURL.appendingPathComponent(Self.eventFileName(sequence, extension: "corrupt")))
            }
        }
        events.sort { $0.sequence < $1.sequence }
        return EventQueue(events: events, nextSequence: highest + 1)
    }
    /// Writes one file per event. If one write fails the files written so far stay: the caller takes them back with `remove`.
    func append(_ events: [QueuedEvent]) throws {
        guard ownsVerifiedFile else { throw TranthorError.storeTemporarilyUnavailable(underlying: CocoaError(.fileWriteNoPermission)) }
        for queued in events { try writeData(JSONEncoder().encode(queued.event), eventURL(queued.sequence)) }
    }
    /// Deletes every event file in the queue folder, however it got there. Set-aside and unrelated files are left.
    /// Every file is tried; the first failure is thrown afterwards.
    func removeAll() throws {
        var failure: (any Error)?
        do {
            for name in try FileManager.default.contentsOfDirectory(atPath: queueURL.path) {
                guard let sequence = Self.leadingSequence(name), name == Self.eventFileName(sequence) else { continue }
                do { try removeFile(queueURL.appendingPathComponent(name)) }
                catch let error as CocoaError where error.code == .fileNoSuchFile {}
                catch { failure = failure ?? error }
            }
        } catch { failure = error }
        if let failure { throw TranthorError.storeTemporarilyUnavailable(underlying: failure) }
    }
    /// Deletes delivered or discarded events and returns the numbers whose file could not be deleted. A file that is already gone is fine.
    @discardableResult
    func remove(_ sequences: [UInt64]) -> [UInt64] {
        var failed: [UInt64] = []
        for sequence in sequences {
            do { try removeFile(eventURL(sequence)) }
            catch let error as CocoaError where error.code == .fileNoSuchFile {}
            catch { failed.append(sequence) }
        }
        return failed
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
            // The flag decides whether a refusal holds a batch, so it is kept with the identity.
            if let supplied = object["identityTokenSupplied"] as? Bool { result.identityTokenSupplied = supplied }
            // So does the point from which queued events name the current user: a signed-out user stays signed out.
            if let epoch = (object["userEpochSequence"] as? NSNumber)?.uint64Value { result.userEpochSequence = epoch }
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

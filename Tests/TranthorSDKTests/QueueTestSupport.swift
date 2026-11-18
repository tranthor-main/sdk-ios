import Foundation
@testable import TranthorSDK

/// A state file as release 0.1.0 wrote it: version 1, with the in-flight batch in `active` and the rest in `queued`.
func releaseZeroOneZeroState(optedOut: Bool = false) -> String {
    """
    {"version":1,"anonymousId":"6F1C2D3E-4A5B-4C6D-8E7F-0123456789AB","userId":"u1","optedOut":\(optedOut),\
    "queued":[{"type":"track","event":"queued1","messageId":"m3","timestamp":"2026-11-01T00:00:03.000Z","userId":"u1"},\
    {"type":"track","event":"queued2","messageId":"m4","timestamp":"2026-11-01T00:00:04.000Z","userId":"u1"}],\
    "active":[{"type":"track","event":"active1","messageId":"m1","timestamp":"2026-11-01T00:00:01.000Z","userId":"u1"},\
    {"type":"track","event":"active2","messageId":"m2","timestamp":"2026-11-01T00:00:02.000Z","userId":"u1"}],\
    "installation":{"token":"ab12","appId":"com.example.app","environment":"production","permission":"granted"},"pendingRemovals":[]}
    """
}

extension ManualTransport {
    /// Lets every request succeed, those already waiting and those still to come, so a test that failed can still shut down.
    func succeedEverything() {
        autoSucceedFutureRequests()
        for index in Array(responses.keys) { complete(index) }
    }
}

extension LoadedStore {
    /// The queued events, oldest first.
    var queued: [[String: JSONValue]] { queue.events.map(\.event) }
}

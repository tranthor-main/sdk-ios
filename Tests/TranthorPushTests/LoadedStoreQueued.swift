import Foundation
@testable import TranthorSDK

extension LoadedStore {
    /// The queued events, oldest first.
    var queued: [[String: JSONValue]] { queue.events.map(\.event) }
}

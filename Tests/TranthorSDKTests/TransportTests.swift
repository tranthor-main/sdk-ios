import XCTest
@testable import TranthorSDK

/// The transport's production timeouts are the documented ones.
final class TransportTests: XCTestCase {
    func testProductionTimeoutsAreDistinctFromHarnessTimeout() throws {
        let transport = try Transport(configuration: Configuration(writeKey: "fixture", host: "http://127.0.0.1:1"))
        defer { transport.shutdown() }
        XCTAssertEqual(transport.session.configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(transport.session.configuration.timeoutIntervalForResource, 60)
    }
}

/// An unusable `host` is a configuration mistake, reported by `configure` as `TranthorError.invalidHost`.
@MainActor
final class InvalidHostTests: XCTestCase {
    func testConfigureThrowsInvalidHostForAnUnusableHost() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-host-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for host in ["", "not a url", "ftp://example.com", "https://", "example.com"] {
            do {
                let sdk = try await TranthorSDK.configure(Configuration(writeKey: "fixture", host: host, storageDirectory: root))
                await sdk.shutdown()
                XCTFail("\(host) was accepted")
            } catch let error as TranthorError {
                XCTAssertEqual(error, .invalidHost, host)
            } catch {
                XCTFail("\(host) threw \(error), not TranthorError.invalidHost")
            }
        }
    }
    func testLoopbackHTTPAndHTTPSHostsAreStillAccepted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("valid-host-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, host) in ["http://127.0.0.1:8080", "https://api.example.com/", "http://192.168.1.20:3001"].enumerated() {
            let sdk = try await TranthorSDK.configure(Configuration(writeKey: "fixture", host: host, storageNamespace: "host-\(index)", storageDirectory: root))
            await sdk.shutdown()
        }
    }
}

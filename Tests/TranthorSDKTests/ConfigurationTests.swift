import Foundation
import XCTest
import TranthorSDK

/// Configuration accepts integer or floating-point option values and replaces invalid ones with defaults.
/// These tests import TranthorSDK without `@testable`, so they also check that the initialisers are public.
@MainActor
final class ConfigurationTests: XCTestCase {
    func testIntegerVariablesAndDefaultOnlyConfigurationAreAccepted() {
        let size = 7, interval = 800, retries = 3, delay = 250
        let configuration = Configuration(writeKey: "fixture", batchSize: size,
            flushIntervalMs: interval, retries: retries, baseDelay: delay)
        XCTAssertEqual(configuration.batchSize, size)
        XCTAssertEqual(configuration.flushIntervalMs, interval)
        XCTAssertEqual(configuration.retries, retries)
        XCTAssertEqual(configuration.baseDelay, Double(delay))
        XCTAssertEqual(Configuration(writeKey: "fixture").batchSize, 5)
        XCTAssertEqual(Configuration(writeKey: "fixture", batchSize: size).batchSize, size)
        XCTAssertEqual(Configuration(writeKey: "fixture", flushIntervalMs: interval).flushIntervalMs, interval)
        XCTAssertEqual(Configuration(writeKey: "fixture", retries: retries).retries, retries)
        XCTAssertEqual(Configuration(writeKey: "fixture", baseDelay: delay).baseDelay, Double(delay))
        // Mixed Int/Double variables use an explicit conversion to the validation initializer.
        let fractionalRetries = 2.8
        XCTAssertEqual(Configuration(writeKey: "fixture", batchSize: Double(size), retries: fractionalRetries).retries, 2)
    }

    func testInvalidIntegerInputsAndNonfiniteDoubleInputsKeepFallbacks() {
        let invalid = -1
        let configuration = Configuration(writeKey: "fixture", batchSize: invalid,
            flushIntervalMs: invalid, retries: invalid, baseDelay: invalid, maxQueueSize: invalid)
        XCTAssertEqual(configuration.batchSize, 5)
        XCTAssertEqual(configuration.flushIntervalMs, 500)
        XCTAssertEqual(configuration.retries, 0)
        XCTAssertEqual(configuration.baseDelay, 0)
        XCTAssertEqual(configuration.maxQueueSize, 10_000)
        XCTAssertEqual(Configuration(writeKey: "fixture", maxQueueSize: 0).maxQueueSize, 10_000)
        XCTAssertEqual(Configuration(writeKey: "fixture", maxQueueSize: 23).maxQueueSize, 23)
        let floating = Configuration(writeKey: "fixture", batchSize: .nan,
            flushIntervalMs: .infinity, retries: 2.8, baseDelay: .infinity)
        XCTAssertEqual(floating.batchSize, 5)
        XCTAssertEqual(floating.flushIntervalMs, 500)
        XCTAssertEqual(floating.retries, 2)
        XCTAssertEqual(floating.baseDelay, 500)
    }

    /// The README table: batchSize and flushIntervalMs are not rounded, a fractional baseDelay is kept.
    func testFractionalBatchSizeAndIntervalUseTheDefaultsAndFractionalDelayIsKept() {
        let configuration = Configuration(writeKey: "fixture", batchSize: 2.5, flushIntervalMs: 99.9, retries: 1.9, baseDelay: 12.5)
        XCTAssertEqual(configuration.batchSize, 5)
        XCTAssertEqual(configuration.flushIntervalMs, 500)
        XCTAssertEqual(configuration.retries, 1)
        XCTAssertEqual(configuration.baseDelay, 12.5)
    }

    func testConsumersCanConstructCallbackFixtures() {
        let failure = DeliveryFailure(status: 429, message: "fixture", retryAfterMs: 1_000)
        let batch = BatchFailure(error: failure, events: [["type": "track", "event": "fixture"]], attempts: 3)
        XCTAssertEqual(batch.error, failure)
        XCTAssertEqual(batch.events.first?["event"], "fixture")
        XCTAssertEqual(batch.attempts, 3)
        XCTAssertEqual(DeliveryFailure(status: nil, message: "fixture").retryAfterMs, 0)
        XCTAssertFalse(TranthorSDKVersion.current.isEmpty)
    }
}

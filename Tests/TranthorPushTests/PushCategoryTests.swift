import Foundation
import UserNotifications
import XCTest
@testable import TranthorPush
@testable import TranthorSDK

/// The server always sends `aps.category = "TRANTHOR_PUSH"`; the SDK registers that category with
/// `customDismissAction` so iOS delivers the dismiss action, merged into the host's own categories.
@MainActor
final class PushCategoryTests: XCTestCase {
    private actor FakeStore: NotificationCategoryStore {
        var current: Set<UNNotificationCategory>
        var writes = 0
        var reads = 0
        /// Runs after each replace: lets a test play the host acting between the SDK's steps.
        var afterReplace: (@Sendable (Int) async -> Void)?
        func setAfterReplace(_ hook: @escaping @Sendable (Int) async -> Void) { afterReplace = hook }
        init(_ initial: CategorySnapshot = CategorySnapshot(categories: [])) { current = initial.categories }
        func categories() async -> CategorySnapshot { reads += 1; return CategorySnapshot(categories: current) }
        func replace(with snapshot: CategorySnapshot) async {
            current = snapshot.categories; writes += 1
            await afterReplace?(writes)
        }
        /// What a host does when it calls setNotificationCategories itself: replaces everything.
        func hostOverwrites(_ snapshot: CategorySnapshot) { current = snapshot.categories }
    }
    private func host(_ id: String, options: UNNotificationCategoryOptions = []) -> UNNotificationCategory {
        categoryFixture(id, options: options)
    }
    private func bound(_ store: FakeStore) async throws -> TranthorPush {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tranthor-category-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let sdk = try await TranthorSDK.configure(Configuration(writeKey: "fixture", host: "http://127.0.0.1:1", flushIntervalMs: 3_600_000,
            storageNamespace: "category", storageDirectory: root))
        return try await TranthorPush(configuration: PushConfiguration(bundleIdentifier: "com.example.category", environment: .development),
                                      sdk: sdk, permission: { .granted }, categoryStore: store)
    }

    func testCategoryHasTheServersIdentifierNoActionsAndTheDismissOption() {
        XCTAssertEqual(PushCategory.identifier, "TRANTHOR_PUSH")
        let category = PushCategory.category
        XCTAssertEqual(category.identifier, "TRANTHOR_PUSH")
        XCTAssertTrue(category.options.contains(.customDismissAction))
        XCTAssertTrue(category.actions.isEmpty)
    }
    func testMergeKeepsEveryHostCategoryAndAddsOurs() throws {
        let a = host("A"), b = host("B", options: .hiddenPreviewsShowTitle)
        let merged = try XCTUnwrap(PushCategory.merged(into: [a, b]))
        XCTAssertEqual(Set(merged.map(\.identifier)), ["A", "B", "TRANTHOR_PUSH"])
        XCTAssertTrue(merged.contains(a) && merged.contains(b), "The host's own objects are kept as they are")
        XCTAssertEqual(try XCTUnwrap(PushCategory.merged(into: [])).map(\.identifier), ["TRANTHOR_PUSH"])
    }
    func testAHostCategoryWithOurIdentifierIsLeftAlone() {
        XCTAssertNil(PushCategory.merged(into: [host("TRANTHOR_PUSH"), host("A")]))
    }

    func testBoundPushRegistersTheCategoryAtStartMergedWithTheHostsCategories() async throws {
        let store = FakeStore(.init(categories: [host("A"), host("B")]))
        _ = try await bound(store)
        let current = await store.categories().categories
        XCTAssertEqual(Set(current.map(\.identifier)), ["A", "B", "TRANTHOR_PUSH"])
        XCTAssertTrue(current.first { $0.identifier == "TRANTHOR_PUSH" }?.options.contains(.customDismissAction) == true)
    }
    func testHostsOwnTranthorPushCategoryIsNeverReplaced() async throws {
        let theirs = host("TRANTHOR_PUSH", options: .hiddenPreviewsShowTitle)
        let store = FakeStore(.init(categories: [theirs]))
        let push = try await bound(store)
        await push.registerNotificationCategory()
        let writes = await store.writes, current = await store.categories().categories
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(current, [theirs])
    }
    func testRegistrationIsIdempotentAndRepairsAnOverwriteWithoutDroppingTheHostsSet() async throws {
        let store = FakeStore(.init(categories: [host("A")]))
        let push = try await bound(store)
        await push.registerNotificationCategory(); await push.registerNotificationCategory()
        var writes = await store.writes
        XCTAssertEqual(writes, 1, "Registered once; later calls find it and write nothing")
        await store.hostOverwrites(.init(categories: [host("A"), host("C")])) // The host replaced the whole set after we started.
        await push.registerNotificationCategory()
        let current = await store.categories().categories
        writes = await store.writes
        XCTAssertEqual(Set(current.map(\.identifier)), ["A", "C", "TRANTHOR_PUSH"])
        XCTAssertEqual(writes, 2)
    }
    // MARK: Read, hop, write: verify after the write and merge again, a couple of times at most
    func testAHostOverwriteRightAfterOurWriteIsRepairedWithoutDroppingTheHostsSet() async throws {
        let store = FakeStore(.init(categories: [host("A")]))
        // The first time we write, the host immediately replaces the whole set (a stale read-modify-write of its own).
        await store.setAfterReplace { [weak store] count in
            if count == 1 { await store?.hostOverwrites(.init(categories: [categoryFixture("A"), categoryFixture("C")])) }
        }
        _ = try await bound(store)
        let current = await store.categories().categories
        XCTAssertEqual(Set(current.map(\.identifier)), ["A", "C", "TRANTHOR_PUSH"], "Merged again into the host's newer set")
    }
    func testACategorySeenBeforeButMissingAfterTheWriteIsMergedBack() async throws {
        let store = FakeStore(.init(categories: [host("A"), host("B")]))
        await store.setAfterReplace { [weak store] count in
            if count == 1 { await store?.hostOverwrites(.init(categories: [categoryFixture("A")])) } // B vanished
        }
        _ = try await bound(store)
        let current = await store.categories().categories
        XCTAssertEqual(Set(current.map(\.identifier)), ["A", "B", "TRANTHOR_PUSH"])
    }
    func testRepairsAreBoundedWhenTheHostKeepsOverwriting() async throws {
        let store = FakeStore(.init(categories: [host("A")]))
        await store.setAfterReplace { [weak store] _ in await store?.hostOverwrites(.init(categories: [categoryFixture("A")])) }
        _ = try await bound(store)
        let writes = await store.writes
        XCTAssertEqual(writes, 3, "Three attempts, then stop: never an endless loop")
    }
    func testAHostRegisteredTranthorPushStillWinsAfterAnOverwrite() async throws {
        let store = FakeStore(.init(categories: [host("A")]))
        await store.setAfterReplace { [weak store] count in
            if count == 1 {
                await store?.hostOverwrites(.init(categories: [categoryFixture("A"), categoryFixture("TRANTHOR_PUSH", options: .hiddenPreviewsShowTitle)]))
            }
        }
        _ = try await bound(store)
        let current = await store.categories().categories, writes = await store.writes
        let ours = current.filter { $0.identifier == "TRANTHOR_PUSH" }
        XCTAssertEqual(ours.count, 1, "Never duplicated")
        XCTAssertEqual(ours.first?.options, .hiddenPreviewsShowTitle, "The host's own definition is kept")
        XCTAssertEqual(writes, 1)
    }
    func testACallThatArrivesWhileARegistrationRunsIsNotLostButRunsAfterIt() async throws {
        let store = FakeStore(.init(categories: [host("A")]))
        let push = try await bound(store)
        await store.hostOverwrites(.init(categories: [host("A")])) // The host dropped our category again.
        let nested = Box()
        // Our write begins; while it is in flight, another caller (an activation) asks again.
        await store.setAfterReplace { _ in await nested.run { await push.registerNotificationCategory() } }
        let readsBefore = await store.reads
        await push.registerNotificationCategory()
        // One pass: read, write, verify = 2 reads. The skipped call forces one more read-and-check, not a silent drop.
        let reads = await store.reads - readsBefore
        XCTAssertEqual(reads, 3)
        let called = await nested.count
        XCTAssertEqual(called, 1)
    }
    func testAfterShutdownAnAppForegroundDoesNotRegisterTheCategoryAgain() async throws {
        let store = FakeStore(.init(categories: [host("A")]))
        let push = try await bound(store)
        var writes = await store.writes
        XCTAssertEqual(writes, 1)
        await push.shutdown()
        await store.hostOverwrites(.init(categories: [host("A")])) // The host replaced the set after shutdown.
        await push.appDidBecomeActive()
        await push.registerNotificationCategory()
        writes = await store.writes
        let current = await store.categories().categories
        XCTAssertEqual(writes, 1, "A stopped TranthorPush must not write the category set")
        XCTAssertEqual(Set(current.map(\.identifier)), ["A"])
    }
    private actor Box { var count = 0; func run(_ work: () async -> Void) async { count += 1; await work() } }
}

private func categoryFixture(_ id: String, options: UNNotificationCategoryOptions = []) -> UNNotificationCategory {
    UNNotificationCategory(identifier: id, actions: [UNNotificationAction(identifier: "act-\(id)", title: "Act", options: [])],
                           intentIdentifiers: [], options: options)
}

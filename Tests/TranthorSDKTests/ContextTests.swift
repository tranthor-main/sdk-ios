import Foundation
import XCTest
@testable import TranthorSDK

/// Automatic context reports a clean OS version and the real device model; timestamps format identically from any thread.
@MainActor
final class ContextTests: XCTestCase {
    func testContextUsesCleanOSVersionAndSimulatorModel() throws {
        let context = automaticContext()
        let osVersion = try XCTUnwrap(context["os"]?["version"]?.string)
        XCTAssertNotNil(osVersion.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression))
        let version = ProcessInfo.processInfo.operatingSystemVersion
        XCTAssertEqual(osVersion, "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
        #if targetEnvironment(simulator)
        if let expected = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            XCTAssertEqual(context["device"]?["model"], .string(expected))
        }
        #endif
        XCTAssertEqual(context["library"]?["version"], .string(TranthorSDKVersion.current))
    }

    func testReusableTimestampFormatterIsSafeUnderConcurrentCalls() async {
        let date = Date(timeIntervalSince1970: 1_577_934_245.006)
        await withTaskGroup(of: String.self) { group in
            for _ in 0..<500 { group.addTask { timestamp(date) } }
            for await value in group { XCTAssertEqual(value, "2020-01-02T03:04:05.006Z") }
        }
        XCTAssertEqual(timestamp(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00.000Z")
    }
}

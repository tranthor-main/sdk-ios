import Foundation
// SwiftPM generates this accessor itself; the Xcode test target uses the same fixtures.
extension Bundle {
    static var module: Bundle { Bundle(for: ConformanceTests.self) }
}

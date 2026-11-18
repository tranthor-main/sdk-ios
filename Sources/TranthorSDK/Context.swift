import Foundation
#if canImport(UIKit)
import UIKit
#endif

private enum TimestampFormatter {
    // Foundation's DateFormatter is Sendable; serialize use explicitly and never mutate after publication.
    static let lock = NSLock()
    static let formatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(secondsFromGMT: 0)
        value.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return value
    }()
}

func timestamp(_ date: Date = Date()) -> String {
    TimestampFormatter.lock.lock()
    defer { TimestampFormatter.lock.unlock() }
    return TimestampFormatter.formatter.string(from: date)
}

func automaticContext() -> [String: JSONValue] {
    let info = Bundle.main.infoDictionary ?? [:]
    #if os(iOS)
    let osName = "iOS"
    #else
    let osName = "macOS"
    #endif
    var system = utsname()
    uname(&system)
    let hardwareModel = withUnsafeBytes(of: &system.machine) { bytes in
        String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    #if targetEnvironment(simulator)
    let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? hardwareModel
    #else
    let model = hardwareModel
    #endif
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    return [
        "library": ["name": "TranthorSDK", "version": .string(TranthorSDKVersion.current)],
        "os": ["name": .string(osName), "version": .string(osVersion)],
        "device": ["model": .string(model)],
        "app": ["name": .string(info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? ""),
                "version": .string(info["CFBundleShortVersionString"] as? String ?? ""),
                "build": .string(info["CFBundleVersion"] as? String ?? "")],
        "locale": .string(Locale.current.identifier), "timezone": .string(TimeZone.current.identifier)
    ]
}

/// The app's `CFBundleShortVersionString`, or "" when unknown (a test host, for example).
func installationAppVersion() -> String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
}
/// "major.minor.patch", the same form as the automatic `os.version` context.
func installationOSVersion() -> String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
}

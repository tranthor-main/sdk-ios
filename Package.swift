// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TranthorSDK",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "TranthorSDK", targets: ["TranthorSDK"]),
               .library(name: "TranthorPush", targets: ["TranthorPush"]),
               .library(name: "TranthorPushService", targets: ["TranthorPushService"])],
    targets: [
        .target(name: "TranthorSDK", resources: [.process("PrivacyInfo.xcprivacy")]),
        // Payload parsing and the badge counter only: no events SDK, safe to link into an app extension.
        .target(name: "TranthorPushPayload"),
        .target(name: "TranthorPush", dependencies: ["TranthorSDK", "TranthorPushPayload"]),
        .target(name: "TranthorPushService", dependencies: ["TranthorPushPayload"], resources: [.process("PrivacyInfo.xcprivacy")]),
        .testTarget(name: "TranthorPushPayloadTests", dependencies: ["TranthorPushPayload"], resources: [.copy("Fixtures")]),
        .testTarget(name: "TranthorPushServiceTests", dependencies: ["TranthorPushService"]),
        .testTarget(name: "TranthorPushTests", dependencies: ["TranthorPush", "TranthorSDK"]),
        .testTarget(name: "TranthorSDKTests", dependencies: ["TranthorSDK"]),
        .testTarget(name: "ConformanceTests", dependencies: ["TranthorSDK"],
                    resources: [.copy("Fixtures")]),
        // Private example model support; not a library product or part of the public SDK API.
        .target(name: "ExampleModelSupport", dependencies: ["TranthorSDK", "TranthorPush", "TranthorPushService"],
                path: "Examples/TranthorExample/Sources", exclude: ["TranthorExampleApp.swift", "ExampleAppDelegate.swift"]),
        .testTarget(name: "ExampleModelTests", dependencies: ["ExampleModelSupport", "TranthorSDK"])
    ],
    swiftLanguageModes: [.v6]
)

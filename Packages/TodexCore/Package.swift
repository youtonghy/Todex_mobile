// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TodexCore",
    // User-facing error text is written in Simplified Chinese; the String
    // Catalog in Resources carries the en/ja/ko translations.
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "TodexCore", targets: ["TodexCore"])],
    dependencies: [
        .package(url: "https://github.com/jedisct1/swift-sodium.git", from: "0.11.0")
    ],
    targets: [
        .target(
            name: "TodexCore", dependencies: [.product(name: "Sodium", package: "swift-sodium")],
            resources: [.process("Resources")]),
        .testTarget(
            name: "TodexCoreTests", dependencies: ["TodexCore"],
            // Cross-language vectors shared verbatim with the backend and TodeX_protocol.
            resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v6]
)

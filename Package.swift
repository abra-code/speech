// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "speech",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "speech", targets: ["speech"]),
        .library(name: "SpeechCore", targets: ["SpeechCore"]),
    ],
    targets: [
        .target(name: "SpeechCore"),
        .target(name: "SpeechApple", dependencies: ["SpeechCore"]),
        .executableTarget(name: "speech", dependencies: ["SpeechCore", "SpeechApple"]),
        .testTarget(name: "SpeechCoreTests", dependencies: ["SpeechCore"]),
    ]
)

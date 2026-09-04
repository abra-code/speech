// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "speech",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "speech", targets: ["speech"]),
        .library(name: "SpeechCore", targets: ["SpeechCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.15.6"),
    ],
    targets: [
        .target(name: "SpeechCore"),
        .target(name: "SpeechApple", dependencies: ["SpeechCore"]),
        .target(name: "SpeechFluid", dependencies: ["SpeechCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "speech", dependencies: ["SpeechCore", "SpeechApple", "SpeechFluid"]),
        .testTarget(name: "SpeechCoreTests", dependencies: ["SpeechCore"]),
        .testTarget(name: "SpeechFluidTests", dependencies: ["SpeechFluid", "SpeechCore"]),
    ]
)

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
        // transcribe.cpp v0.2.3, consumed as the published xcframework plus its
        // own Swift wrapper vendored under Sources/TranscribeCpp (MIT). The
        // checksum is of the release asset; `swift package compute-checksum`
        // reproduces it.
        .binaryTarget(
            name: "CTranscribe",
            url: "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.2.3/TranscribeCpp.xcframework.zip",
            checksum: "944be4d5232f39c99608f676a2ddda2516e0ed3c9fb6db50685ffa8d20a8b9c9"
        ),
        .target(
            name: "TranscribeCpp",
            dependencies: ["CTranscribe"],
            exclude: ["LICENSE", "THIRD-PARTY-LICENSES.md"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .target(name: "SpeechCore"),
        // The `speech` half of the speech-mlx wire format. Foundation only,
        // and deliberately not a dependent of SpeechCore: the helper's Xcode
        // project compiles this same directory, and it must not drag
        // FluidAudio or the transcribe.cpp xcframework into a binary that
        // links nothing but MLX.
        .target(name: "SpeechMLXProtocol"),
        // The supervisor for the optional speech-mlx helper. It depends on the
        // wire format and nothing else: no SpeechCore, so that the target stays
        // buildable and testable on its own, and no MLX, which lives entirely
        // in the other binary.
        .target(name: "SpeechMLX", dependencies: ["SpeechCore", "SpeechMLXProtocol"]),
        .target(name: "SpeechApple", dependencies: ["SpeechCore"]),
        .target(name: "SpeechFluid", dependencies: ["SpeechCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .target(name: "SpeechGGML", dependencies: ["SpeechCore", "TranscribeCpp"]),
        .executableTarget(
            name: "speech",
            dependencies: ["SpeechCore", "SpeechApple", "SpeechFluid", "SpeechGGML", "SpeechMLX"]),
        .testTarget(name: "SpeechCoreTests", dependencies: ["SpeechCore"]),
        .testTarget(name: "SpeechMLXProtocolTests", dependencies: ["SpeechMLXProtocol"]),
        .testTarget(name: "SpeechMLXTests", dependencies: ["SpeechMLX", "SpeechCore", "SpeechMLXProtocol"]),
        .testTarget(name: "SpeechFluidTests", dependencies: ["SpeechFluid", "SpeechCore"]),
        .testTarget(name: "SpeechGGMLTests", dependencies: ["SpeechGGML", "SpeechCore"]),
    ]
)

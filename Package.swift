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
        // A range, not an exact pin: build.sh moves to the newest release it
        // allows before every build (tools/update-packages.sh), and the
        // committed Package.resolved records the exact version each build used.
        // `./build.sh --no-update` builds exactly what that file pins.
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.15.6"),
    ],
    targets: [
        // transcribe.cpp at the release in patches/transcribe.cpp/PIN, built
        // from source, plus its own Swift wrapper vendored under
        // Sources/TranscribeCpp (MIT).
        //
        // Not the published release asset: speech needs two fixes no release
        // carries - the Parakeet streaming commit freeze and the Metal
        // out-of-memory crash - so tools/vendor-transcribe.sh clones the pinned
        // tag, applies patches/transcribe.cpp/, and builds the xcframework this
        // target points at. The pin and the patches are in this repository, so
        // the framework is reproducible; vendor/ itself is not committed.
        //
        // `swift build` on its own fails here with "artifact not found" until
        // that script has run once. ./build.sh and ./test.sh run it for you.
        .binaryTarget(
            name: "CTranscribe",
            path: "vendor/TranscribeCpp.xcframework"
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
        // The optional speech-mlx helper: the supervisor that runs it and the
        // engine that decides what to ask it for. No MLX here - that lives
        // entirely in the other binary, which is the whole point - so this
        // target builds and tests on a machine with none.
        .target(name: "SpeechMLX", dependencies: ["SpeechCore", "SpeechMLXProtocol"]),
        .target(name: "SpeechApple", dependencies: ["SpeechCore"]),
        .target(name: "SpeechFluid", dependencies: ["SpeechCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .target(name: "SpeechGGML", dependencies: ["SpeechCore", "TranscribeCpp"]),
        .executableTarget(
            name: "speech",
            dependencies: ["SpeechCore", "SpeechApple", "SpeechFluid", "SpeechGGML", "SpeechMLX"]),
        .testTarget(name: "SpeechCoreTests", dependencies: ["SpeechCore"]),
        .testTarget(name: "SpeechAppleTests", dependencies: ["SpeechApple", "SpeechCore"]),
        .testTarget(name: "SpeechMLXProtocolTests", dependencies: ["SpeechMLXProtocol"]),
        .testTarget(name: "SpeechMLXTests", dependencies: ["SpeechMLX", "SpeechCore", "SpeechMLXProtocol"]),
        .testTarget(name: "SpeechFluidTests", dependencies: ["SpeechFluid", "SpeechCore"]),
        .testTarget(name: "SpeechGGMLTests", dependencies: ["SpeechGGML", "SpeechCore"]),
    ]
)

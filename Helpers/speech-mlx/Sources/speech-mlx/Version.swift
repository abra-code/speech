// Version.swift - what produced a given answer.
//
// The same discipline as `SpeechEnvironment` in the main binary: a number
// measured with this helper is a number produced by these dependency versions,
// and a run that does not record them is not reproducible. Neither mlx-swift
// nor mlx-audio-swift exposes a runtime version, so these are the versions the
// project's Package.resolved pins. build-speech-mlx.sh's update step
// (tools/update-packages.sh) rewrites them whenever those move, and
// `helperPinsMatchTheProject` in the main test suite fails when they drift,
// because a stale version string is worse than none.

enum HelperVersion {
    static let helper = "0.1.0"
    static let mlxAudio = "0.1.3"
    static let mlxSwift = "0.31.6"
}

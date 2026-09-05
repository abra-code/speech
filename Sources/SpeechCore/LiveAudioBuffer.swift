// LiveAudioBuffer.swift - the recent microphone audio, addressable by time.
//
// Live refinement needs to hand a *second* engine the samples a first engine
// has just turned into a `segment.final`. Nothing else in the program keeps
// live audio around: a session feeds its engine and forgets, which is right for
// the session and useless for this.
//
// So one buffer, one rule: audio is addressed by seconds since capture started,
// never by index into an array whose front keeps being dropped. The absolute
// sample counter is the identity; the array is just where the still-retained
// part of it happens to live.
//
// Memory is the whole reason this is not simply `var samples: [Float]`. At
// 16 kHz Float32 an hour of dictation is 230 MB, and a live session is expected
// to run for exactly that long. Two independent caps keep it bounded: the
// consumer drops everything behind a segment it has finished with, and the
// buffer itself refuses to retain more than `retainedSeconds` no matter what
// the consumer does - because an engine that never emits a final (a dead
// stream, a model that hung) must not also become a memory leak.

import Foundation

public actor LiveAudioBuffer {
    /// Samples per second of everything stored here. Always the project's
    /// canonical rate: the buffer holds what an engine would be measured on,
    /// not what the hardware happened to produce.
    public let sampleRate: Double
    /// Hard ceiling on retained audio, enforced on every append.
    public let retainedSeconds: Double

    private var samples: [Float] = []
    /// Absolute index of `samples[0]` - the number of samples dropped off the
    /// front since capture began. This is what makes a time-addressed slice
    /// possible after trimming.
    private var origin: Int = 0
    /// Total appended, ever.
    private var written: Int = 0

    public init(sampleRate: Double = AudioDecoder.sampleRate, retainedSeconds: Double = 300) {
        self.sampleRate = sampleRate
        self.retainedSeconds = retainedSeconds
    }

    /// Seconds of audio captured so far, whether or not still retained.
    public var capturedSeconds: Double { Double(written) / sampleRate }

    /// Seconds currently sliceable, i.e. the length of the retained window.
    public var retainedWindow: (start: Double, end: Double) {
        (Double(origin) / sampleRate, Double(written) / sampleRate)
    }

    public func append(_ new: [Float]) {
        guard !new.isEmpty else { return }
        samples.append(contentsOf: new)
        written += new.count
        enforceCeiling()
    }

    /// The samples covering `start..<end` seconds since capture start.
    ///
    /// Returns what it has rather than nothing when the request runs off either
    /// end, and nil only when the overlap is empty. A segment whose head has
    /// already been trimmed is better refined from its tail than not at all,
    /// and the caller cannot know where the trim line is without asking.
    public func slice(from start: Double, to end: Double) -> [Float]? {
        // `end > start` is also the NaN guard: every comparison against NaN is
        // false, so a NaN at either end lands here rather than in the
        // conversion. Infinities are clamped by `index(ofSecond:)`.
        guard end > start else { return nil }
        let lower = max(index(ofSecond: start), origin)
        let upper = min(index(ofSecond: end), written)
        guard upper > lower else { return nil }
        return Array(samples[(lower - origin)..<(upper - origin)])
    }

    /// Forget everything before `seconds`. Cheap to call after every final.
    public func discard(before seconds: Double) {
        let cut = index(ofSecond: seconds)
        guard cut > origin else { return }
        let drop = min(cut - origin, samples.count)
        guard drop > 0 else { return }
        samples.removeFirst(drop)
        origin += drop
    }

    public func reset() {
        samples.removeAll(keepingCapacity: false)
        origin = 0
        written = 0
    }

    /// Seconds to an absolute sample index, saturating rather than trapping.
    ///
    /// `Int(_:)` on a `Double` traps on NaN and on anything past `Int.max`, and
    /// this is a `public actor` whose timestamps will soon come from whichever
    /// engine a live session happens to be running. A crash is not an acceptable
    /// answer to a model reporting a bad time range.
    private func index(ofSecond seconds: Double, clampedTo ceiling: Int? = nil) -> Int {
        let upper = ceiling ?? written
        let scaled = (seconds * sampleRate).rounded()
        // NaN first, because every comparison against it is false and it would
        // otherwise fall through to the `Int()` conversion that traps on it.
        // Infinities are clamped by the two range tests below, each in the
        // direction it points.
        if scaled.isNaN { return 0 }
        if scaled <= 0 { return 0 }
        if scaled >= Double(upper) { return upper }
        return Int(scaled)
    }

    /// The safety net. Trims from the front when the window overflows.
    ///
    /// Trims down to `trimTarget` of the ceiling rather than exactly to it,
    /// because `removeFirst` shifts everything behind it: trimming to the line
    /// would memmove the whole retained window on *every* append once the
    /// ceiling is reached, which at 300 seconds of 16 kHz audio and a 4096-frame
    /// tap is about 225 MB/s of pure copying for as long as the session runs.
    /// Trimming in chunks makes it one memmove per chunk instead.
    private func enforceCeiling() {
        // Through the same saturating conversion the timestamps use. Both
        // `retainedSeconds` and `sampleRate` are `public init` parameters, and
        // guarding one arithmetic path against a hostile Double while leaving
        // the other to trap would be a strange place to stop.
        let ceiling = index(ofSecond: retainedSeconds, clampedTo: Int.max)
        guard ceiling > 0, samples.count > ceiling else { return }
        let keep = max(1, Int(Double(ceiling) * Self.trimTarget))
        let drop = samples.count - keep
        guard drop > 0 else { return }
        samples.removeFirst(drop)
        origin += drop
    }

    /// How much of the ceiling to keep after a trim.
    private static let trimTarget = 0.8
}

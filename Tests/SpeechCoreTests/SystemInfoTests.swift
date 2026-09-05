// SystemInfoTests.swift - the memory snapshot reads a C struct that has grown
// seven revisions by rebinding it to a word array, so the failure mode is not
// "wrong answer" but "plausible-looking garbage from the wrong offset". These
// tests are bounds checks against physical RAM for exactly that reason: a
// misread field lands orders of magnitude outside them.

import Testing
@testable import SpeechCore

@Suite("SystemInfo memory")
struct SystemInfoTests {
    @Test("the snapshot is available on a supported system")
    func snapshotExists() throws {
        // The floor is macOS 15 and the ledgers arrived long before it, so nil
        // here is a bug in the offset arithmetic rather than an old kernel.
        _ = try #require(
            SystemInfo.memorySnapshot(),
            "TASK_VM_INFO did not fill the ledger fields macOS 15 is expected to carry")
    }

    @Test("every field is a plausible size for this machine")
    func fieldsAreInRange() throws {
        let snapshot = try #require(SystemInfo.memorySnapshot())
        let physical = SystemInfo.physicalMemoryBytes
        #expect(physical > 0)

        // A test process is a few tens of megabytes. The lower bound catches a
        // field read as zero; the upper bound catches one read from the wrong
        // offset, which yields a pointer-sized number far above installed RAM.
        #expect(snapshot.residentPeak > 1_000_000)
        #expect(snapshot.residentPeak < physical)
        #expect(snapshot.footprintPeak > 1_000_000)
        #expect(snapshot.footprintPeak < physical)

        // Nothing here loads a CoreML model, so the Neural Engine mapping is
        // expected to be empty - but the assertion that matters is that it is
        // never negative, because the ledger is a signed field and a bad read
        // shows up as a large negative number.
        #expect(snapshot.neuralPeak >= 0)
        #expect(snapshot.neuralPeak < physical)
    }

    @Test("peak is the sum of its two halves, and never smaller than either")
    func peakIsTheSum() throws {
        let snapshot = try #require(SystemInfo.memorySnapshot())
        #expect(snapshot.peak == snapshot.footprintPeak + snapshot.neuralPeak)
        #expect(snapshot.peak >= snapshot.footprintPeak)
        #expect(snapshot.peak >= snapshot.neuralPeak)
    }

    @Test("peakMemoryBytes answers even though it is allowed to fall back")
    func peakMemoryAlwaysAnswers() {
        #expect(SystemInfo.peakMemoryBytes() > 1_000_000)
    }

    @Test("ru_maxrss is bytes on Darwin, not the kilobytes the manual claims")
    func residentBytesAreBytes() {
        // A ported 1024x error would put a test process at tens of gigabytes
        // or tens of kilobytes; both are excluded here.
        let resident = SystemInfo.peakResidentBytes()
        #expect(resident > 1_000_000)
        #expect(resident < SystemInfo.physicalMemoryBytes)
    }
}

// SystemInfo.swift - what `speech info` and `speech catalog` report about the
// machine: physical RAM, the chip, the OS version, and what this process's
// memory cost.
//
// The memory readings are here rather than in the evaluator because several
// callers need them - `done` events and `eval.summary` - and because the
// macOS-specific details deserve exactly one comment in the codebase rather
// than one per call site. There are two of those details and both are traps:
// `ru_maxrss` is bytes on Darwin where the manuals say kilobytes, and peak RSS
// is not a repeatable measure of what a CoreML model costs. See
// `MemorySnapshot` for the second.

import Foundation

public enum SystemInfo {
    /// Peak resident set size of this process, in bytes.
    ///
    /// On Darwin `ru_maxrss` is bytes; the BSD and Linux manuals say kilobytes,
    /// which is the usual source of a 1024x error in ported code. Verified
    /// against `/usr/bin/time -l` output on macOS.
    public static func peakResidentBytes() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Int64(usage.ru_maxrss)
    }

    /// What this process's memory actually cost, taken from one
    /// `TASK_VM_INFO` call so the fields are mutually consistent.
    ///
    /// `ru_maxrss` alone is not a repeatable answer for a CoreML process. It
    /// counts clean file-backed pages, and whether a model's weight pages are
    /// counted in *our* address space during the hand-off to the Neural Engine
    /// is decided by the system, not by us: two identical `speech eval` runs
    /// minutes apart measured 78 MB and 677 MB. The ledgers below do not move -
    /// across five runs of the same command the ANE figure was identical to the
    /// byte and the footprint varied by under 1 MB.
    public struct MemorySnapshot: Sendable {
        /// Peak resident bytes, the same number `ru_maxrss` reports. Kept
        /// because published figures for other tools are RSS, and dropped from
        /// every comparison we make ourselves.
        public var residentPeak: Int64
        /// Peak physical footprint: dirty plus compressed plus accounted
        /// device memory, excluding evictable clean file pages. This is what
        /// Activity Monitor calls "Memory" and what jetsam kills on.
        public var footprintPeak: Int64
        /// Peak Neural Engine memory mapped by this process and *not* charged
        /// to its footprint, which is where a CoreML model's weights live. For
        /// `fluid.parakeet-v3@int8` this is 490,487,808 bytes on every run.
        ///
        /// Weights that a future OS charges to the footprint instead land in
        /// `footprintPeak`, so `peak` stays right either way and never double
        /// counts.
        public var neuralPeak: Int64

        /// The number to quote: the process's own memory plus the model the
        /// Neural Engine holds for it. Neither half alone is the cost.
        public var peak: Int64 { footprintPeak + neuralPeak }
    }

    /// One `TASK_VM_INFO` call, or nil when the kernel did not fill the ledger
    /// fields this needs (`ledger_phys_footprint_peak` arrived in revision 3,
    /// the neural peak in revision 7; macOS 15, our floor, has both).
    ///
    /// Nil rather than a partial answer on purpose. A snapshot missing the
    /// neural ledger would report 70 MB for a model that costs 570, and a
    /// number that wrong is worse than no number.
    public static func memorySnapshot() -> MemorySnapshot? {
        var info = task_vm_info_data_t()
        let capacity = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        var count = mach_msg_type_number_t(capacity)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        // `count` comes back as the number of 4-byte words the kernel actually
        // filled, which is how a struct that has grown seven times stays
        // readable by an old caller. A field is real only if it ends at or
        // before that mark, so each one is checked against its own offset
        // rather than against an assumed revision.
        let filledBytes = Int(count) * MemoryLayout<natural_t>.size
        func isFilled(_ keyPath: PartialKeyPath<task_vm_info_data_t>) -> Bool {
            guard let offset = MemoryLayout<task_vm_info_data_t>.offset(of: keyPath) else {
                return false
            }
            return offset + MemoryLayout<Int64>.size <= filledBytes
        }
        guard isFilled(\task_vm_info_data_t.ledger_phys_footprint_peak),
              isFilled(\task_vm_info_data_t.ledger_tag_neural_nofootprint_peak)
        else { return nil }
        return MemorySnapshot(
            residentPeak: Int64(info.resident_size_peak),
            footprintPeak: Int64(info.ledger_phys_footprint_peak),
            neuralPeak: Int64(info.ledger_tag_neural_nofootprint_peak))
    }

    /// `memorySnapshot()?.peak`, falling back to the resident peak on a kernel
    /// too old to answer. Callers that report the number to a human should say
    /// which one they got; callers that just need a figure can use this.
    public static func peakMemoryBytes() -> Int64 {
        memorySnapshot()?.peak ?? peakResidentBytes()
    }

    public static var physicalMemoryBytes: Int64 {
        Int64(ProcessInfo.processInfo.physicalMemory)
    }

    public static var operatingSystemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// True when the running system is at least the given "major.minor" string.
    /// Used to answer "can this catalog row run here" without every caller
    /// parsing version strings.
    public static func isAtLeast(_ version: String) -> Bool {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        let target = OperatingSystemVersion(
            majorVersion: parts.count > 0 ? parts[0] : 0,
            minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(target)
    }

    /// "Apple M5", from the same sysctl `system_profiler` reads. Empty when the
    /// key is missing, which is only the case on non-Apple-Silicon builds.
    public static var chip: String {
        sysctlString("machdep.cpu.brand_string") ?? sysctlString("hw.model") ?? ""
    }

    public static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // sysctl reports the length including the terminator; drop it and
        // anything after it before handing the bytes to String.
        let bytes = buffer.prefix(while: { $0 != 0 })
        return String(decoding: bytes, as: UTF8.self)
    }

    /// "1.4 GB", "740 MB", "12 KB". Decimal units, matching how Hugging Face
    /// and Finder report download sizes, so a card's number matches the site's.
    public static func formatBytes(_ bytes: Int64) -> String {
        let units: [(Int64, String, Int)] = [
            (1_000_000_000, "GB", 2),
            (1_000_000, "MB", 0),
            (1_000, "KB", 0),
        ]
        for (scale, suffix, digits) in units where bytes >= scale {
            let value = Double(bytes) / Double(scale)
            return String(format: "%.\(digits)f %@", value, suffix)
        }
        return "\(bytes) B"
    }
}

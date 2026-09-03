// SystemInfo.swift - what `speech info` reports and what stage 3's curation
// divides by: physical RAM, the chip, the OS version, and this process's peak
// resident size.
//
// Peak RSS is here rather than in the evaluator because two callers need it -
// `done` events and `eval.summary` - and because the macOS-specific detail
// (ru_maxrss is bytes here, kilobytes on Linux) deserves exactly one comment in
// the codebase rather than one per call site.

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

import Foundation

/// A CPU / XCPM OpenCore `Kernel → Patch`. Unlike the port-limit patch these
/// are CPU- *and* build-specific (they encode core counts, MSR-table offsets
/// and topology bytes), so the app ships them as a verified reference set for
/// this machine (i9-13900K, macOS 26.x / Darwin 25) rather than deriving them
/// blind. The "Verify" action checks each against the live Kernel Collection.
struct XCPMPatch: Identifiable {
    let id = UUID()
    let name: String
    let identifier: String
    var base: String = ""          // symbol anchor; empty = raw whole-kernel scan
    var cpus: String = ""          // which Intel CPUs this exact patch applies to
    let find: [UInt8]
    let replace: [UInt8]
    let mask: [UInt8]          // empty = exact match
    let count: Int
    let minKernel: String
    let maxKernel: String
    let note: String

    // Verification result (filled after a live-KC scan)
    var matched: Bool? = nil
    var hits: Int = 0

    private func hx(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
    var findHex: String { hx(find) }
    var replaceHex: String { hx(replace) }
    var findB64: String { Data(find).base64EncodedString() }
    var replaceB64: String { Data(replace).base64EncodedString() }
    var maskB64: String { mask.isEmpty ? "" : Data(mask).base64EncodedString() }

    func plistSnippet() -> String {
        """
        <dict>
            <key>Arch</key>
            <string>x86_64</string>
            <key>Base</key>
            <string>\(base)</string>
            <key>Comment</key>
            <string>\(name)</string>
            <key>Count</key>
            <integer>\(count)</integer>
            <key>Enabled</key>
            <true/>
            <key>Find</key>
            <data>\(findB64)</data>
            <key>Identifier</key>
            <string>\(identifier)</string>
            <key>Limit</key>
            <integer>0</integer>
            <key>Mask</key>
            <data>\(maskB64)</data>
            <key>MaxKernel</key>
            <string>\(maxKernel)</string>
            <key>MinKernel</key>
            <string>\(minKernel)</string>
            <key>Replace</key>
            <data>\(replaceB64)</data>
            <key>ReplaceMask</key>
            <data></data>
            <key>Skip</key>
            <integer>0</integer>
        </dict>
        """
    }
}

enum XCPMLibrary {

    /// Verified against macOS build 25F84 (Tahoe) on an i9-13900K. These are
    /// CPU + build specific — re-verify after a macOS update.
    static let reference: [XCPMPatch] = [
        XCPMPatch(
            name: "AppleXcpmExtraMsrs — Core scope",
            identifier: "kernel",
            cpus: "Raptor Lake family — i9-13900K, i9-14900K, i7-13700K/14700K (MSR table is build-specific; re-verify after macOS updates)",
            find:    [0x4C,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x0F,0x04,0x00,0x00],
            replace: [0x4C,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x4C,0x00,0x00,0x00],
            mask: [], count: 1, minKernel: "25.0.0", maxKernel: "25.99.99",
            note: "Stops XCPM writing unsupported per-core MSRs on the hybrid CPU."),
        XCPMPatch(
            name: "AppleXcpmExtraMsrs — Package scope",
            identifier: "kernel",
            cpus: "Raptor Lake family — i9-13900K, i9-14900K, i7-13700K/14700K (MSR table is build-specific)",
            find:    [0x04,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x04,0x00,0x00,0x00,0x00,0x00,0x00,0x00],
            replace: [0x04,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xDC,0x73,0x06,0x00,0x00,0x00,0x00,0x00],
            mask: [], count: 10, minKernel: "25.0.0", maxKernel: "25.99.99",
            note: "Package-scope MSR table entry for XCPM."),
        XCPMPatch(
            name: "AppleXcpmExtraMsrs — SMT scope",
            identifier: "kernel",
            cpus: "Raptor Lake family — i9-13900K, i9-14900K, i7-13700K/14700K (MSR table is build-specific)",
            find:    [0x04,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x04,0x00,0x00,0x00,0x00,0x00],
            replace: [0x04,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x04,0x00,0x00,0x00,0x00,0x00,0x00],
            mask: [], count: 1, minKernel: "25.0.0", maxKernel: "25.99.99",
            note: "SMT-scope MSR table entry for XCPM."),
        XCPMPatch(
            name: "AppleCpuPmCfgLock — Core count 8 → 64",
            identifier: "kernel", base: "_cpu_pm_core_count",
            cpus: "Any Intel up to 64 cores — 12th/13th/14th Gen (i9-12900K, i9-13900K, i9-14900K, i7-14700K …). Raises the limit, so it is not tied to one core count.",
            find:    [0x83,0xF8,0x80],
            replace: [0x83,0xF8,0x00],
            mask: [], count: 1, minKernel: "25.0.0", maxKernel: "25.99.99",
            note: "Raises the XCPM core-count comparison so all cores are handled."),
        XCPMPatch(
            name: "Fix CPU topology — Alder/Raptor Lake (c1e108 → c1e118)",
            identifier: "kernel",
            cpus: "12th/13th/14th Gen hybrid — Alder Lake, Raptor Lake, Raptor Lake Refresh (i9-12900K, i9-13900K, i9-14900K, i7-13700K/14700K). NOT needed on Arrow Lake / Core Ultra 200S (no HT, different topology).",
            find:    [0xC1,0xE1,0x08],
            replace: [0xC1,0xE1,0x18],
            mask: [], count: 1, minKernel: "25.0.0", maxKernel: "25.99.99",
            note: "Corrects hybrid P/E-core topology so all threads are scheduled."),
    ]

    static let bootKCPath = "/System/Library/KernelCollections/BootKernelExtensions.kc"

    /// Verifies each patch's Find against the live Kernel Collection.
    /// Returns copies with `matched`/`hits` filled, plus a diagnostic log.
    static func verify(_ patches: [XCPMPatch], path: String = bootKCPath) -> (result: [XCPMPatch], log: String) {
        guard let data = FileManager.default.contents(atPath: path) else {
            return (patches, "Could not read \(path). If permission-denied, this needs elevated access the app can't grant; check via check_patches.py instead.")
        }
        var log = "Kernel Collection: \(path) (\(data.count / (1024*1024)) MB)\n"
        var out = patches
        for i in out.indices {
            let c = count(in: data, find: out[i].find, mask: out[i].mask)
            out[i].hits = c
            out[i].matched = c > 0
            log += "\(out[i].name): \(c > 0 ? "MATCH (\(c))" : "BROKEN — not found")\n"
        }
        return (out, log)
    }

    /// Count occurrences of `find` under `mask` (empty mask = exact) in `data`.
    static func count(in data: Data, find: [UInt8], mask: [UInt8]) -> Int {
        let n = find.count
        guard n > 0, data.count >= n else { return 0 }
        let m = (mask.count == n) ? mask : [UInt8](repeating: 0xFF, count: n)
        let ai = m.firstIndex(of: 0xFF) ?? 0
        let anchor = find[ai]
        return data.withUnsafeBytes { raw -> Int in
            let p = raw.bindMemory(to: UInt8.self)
            let L = p.count
            guard L >= n else { return 0 }
            var count = 0
            var i = 0
            let limit = L - n
            while i <= limit {
                if p[i + ai] == anchor {
                    var ok = true
                    var k = 0
                    while k < n {
                        if (p[i + k] & m[k]) != (find[k] & m[k]) { ok = false; break }
                        k += 1
                    }
                    if ok { count += 1 }
                }
                i += 1
            }
            return count
        }
    }
}

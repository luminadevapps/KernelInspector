import Foundation

/// Where a derived patch came from.
enum PatchOrigin {
    case binary            // scanned from a loaded .kext / Mach-O
    case kernelCollection  // derived from the live BootKernelExtensions.kc
    case reference         // known-good verified pattern shipped with the app
}

/// Derives an XHCI **port-limit** OpenCore `Kernel → Patch` from real bytes —
/// either a loaded binary or the live Kernel Collection — instead of relying on
/// a hard-coded pattern that only matches one macOS build.
struct PortLimitMatch: Identifiable {
    let id = UUID()
    let functionName: String
    let identifier: String
    let vmaddr: UInt64
    let fileOffset: Int            // offset of the Find window (in the scanned file)
    let immOffsetInWindow: Int
    let find: [UInt8]
    let replace: [UInt8]
    let newLimit: UInt8
    var verified: Bool
    var origin: PatchOrigin = .binary

    var findHex: String { find.map { String(format: "%02X", $0) }.joined(separator: " ") }
    var replaceHex: String { replace.map { String(format: "%02X", $0) }.joined(separator: " ") }
    var findB64: String { Data(find).base64EncodedString() }
    var replaceB64: String { Data(replace).base64EncodedString() }

    var comment: String {
        "XHCI port limit 15→\(newLimit) — derived by Kernel Inspector | \(functionName)"
    }

    func plistSnippet() -> String {
        """
        <dict>
            <key>Arch</key>
            <string>x86_64</string>
            <key>Base</key>
            <string>\(functionName)</string>
            <key>Comment</key>
            <string>\(comment)</string>
            <key>Count</key>
            <integer>1</integer>
            <key>Enabled</key>
            <true/>
            <key>Find</key>
            <data>\(findB64)</data>
            <key>Identifier</key>
            <string>\(identifier)</string>
            <key>Limit</key>
            <integer>0</integer>
            <key>Mask</key>
            <data></data>
            <key>MaxKernel</key>
            <string></string>
            <key>MinKernel</key>
            <string></string>
            <key>Replace</key>
            <data>\(replaceB64)</data>
            <key>ReplaceMask</key>
            <data></data>
            <key>Skip</key>
            <integer>0</integer>
        </dict>
        """
    }

    // MARK: - Universal (masked) form
    //
    // Matches the instruction `cmp <reg32>, 0x0F` itself and ignores the
    // build-specific surrounding bytes, so one patch works across macOS builds.
    // Find 83 F8 0F / Mask FF F8 FF locks the opcode + immediate but wildcards
    // the register; ReplaceMask 00 00 FF rewrites only the immediate to newLimit.
    // `Base` scopes it to the function and Count 1 hits the port-limit compare.

    var maskedFind: [UInt8] { [0x83, 0xF8, 0x0F] }
    var maskedMask: [UInt8] { [0xFF, 0xF8, 0xFF] }
    var maskedReplace: [UInt8] { [0x00, 0x00, newLimit] }
    var maskedReplaceMask: [UInt8] { [0x00, 0x00, 0xFF] }

    private func hx(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
    var maskedFindHex: String { hx(maskedFind) }
    var maskedMaskHex: String { hx(maskedMask) }
    var maskedReplaceHex: String { hx(maskedReplace) }
    var maskedReplaceMaskHex: String { hx(maskedReplaceMask) }
    var maskedFindB64: String { Data(maskedFind).base64EncodedString() }
    var maskedMaskB64: String { Data(maskedMask).base64EncodedString() }
    var maskedReplaceB64: String { Data(maskedReplace).base64EncodedString() }
    var maskedReplaceMaskB64: String { Data(maskedReplaceMask).base64EncodedString() }

    func maskedPlistSnippet() -> String {
        """
        <dict>
            <key>Arch</key>
            <string>x86_64</string>
            <key>Base</key>
            <string>\(functionName)</string>
            <key>Comment</key>
            <string>XHCI port limit 15→\(newLimit) — universal masked (Kernel Inspector)</string>
            <key>Count</key>
            <integer>1</integer>
            <key>Enabled</key>
            <true/>
            <key>Find</key>
            <data>\(maskedFindB64)</data>
            <key>Identifier</key>
            <string>\(identifier)</string>
            <key>Limit</key>
            <integer>0</integer>
            <key>Mask</key>
            <data>\(maskedMaskB64)</data>
            <key>MaxKernel</key>
            <string></string>
            <key>MinKernel</key>
            <string></string>
            <key>Replace</key>
            <data>\(maskedReplaceB64)</data>
            <key>ReplaceMask</key>
            <data>\(maskedReplaceMaskB64)</data>
            <key>Skip</key>
            <integer>0</integer>
        </dict>
        """
    }
}

enum PortLimitScanner {

    static let windowLength = 16
    static let bootKCPath = "/System/Library/KernelCollections/BootKernelExtensions.kc"

    static let knownFunctions: [(needle: String, identifier: String)] = [
        ("createPorts",      "com.apple.driver.usb.AppleUSBXHCI"),
        ("setPortLocation",  "com.apple.iokit.IOUSBHostFamily"),
        ("PortLimit",        ""),
        ("getPortCount",     ""),
    ]

    // MARK: - Verified reference (build 25F84, macOS Tahoe)

    /// Known-good patterns confirmed against macOS build 25F84. Handy as a quick
    /// copy or a sanity check when a live scan isn't available.
    static func reference25F84(newLimit: UInt8 = 0x40) -> [PortLimitMatch] {
        func mk(_ find: [UInt8], _ imm: Int, _ id: String, _ sym: String) -> PortLimitMatch {
            var r = find; r[imm] = newLimit
            return PortLimitMatch(functionName: sym, identifier: id, vmaddr: 0, fileOffset: -1,
                                  immOffsetInWindow: imm, find: find, replace: r,
                                  newLimit: newLimit, verified: true, origin: .reference)
        }
        return [
            mk([0x83,0xF8,0x0F,0x0F,0x83,0xD8,0x07,0x00,0x00,0x48,0x89,0x5D,0xB0,0x8D,0x58,0x01], 2,
               "com.apple.driver.usb.AppleUSBXHCI", "__ZN12AppleUSBXHCI11createPortsEv"),
            mk([0x41,0x83,0xFF,0x0F,0x0F,0x87,0x40,0x04,0x00,0x00,0x48,0x8B,0x03,0x48,0x89,0xDF], 3,
               "com.apple.iokit.IOUSBHostFamily", "__ZN16AppleUSBHostPort15setPortLocationEv"),
        ]
    }

    // MARK: - Loaded-binary scan

    static func scan(image: MachOImage, data: Data, bundleID: String?, newLimit: UInt8 = 0x40) -> [PortLimitMatch] {
        let syms = image.symbols
            .filter { $0.isDefined && !$0.isDebug && $0.value != 0 }
            .sorted { $0.value < $1.value }
        guard !syms.isEmpty else { return [] }

        func nextAddr(after i: Int) -> UInt64 { i + 1 < syms.count ? syms[i + 1].value : UInt64.max }

        var matches: [PortLimitMatch] = []
        for (i, sym) in syms.enumerated() {
            guard let known = knownFunctions.first(where: { sym.name.contains($0.needle) }) else { continue }
            let start = sym.value
            let end = min(nextAddr(after: i), start + 4096)
            let id = known.identifier.isEmpty ? (bundleID ?? "") : known.identifier
            matches += scanRange(image: image, data: data, start: start, end: end,
                                 functionName: sym.name, identifier: id, newLimit: newLimit, verified: true)
        }
        if matches.isEmpty {
            for (i, sym) in syms.enumerated() {
                let start = sym.value
                let end = min(nextAddr(after: i), start + 512)
                matches += scanRange(image: image, data: data, start: start, end: end,
                                     functionName: sym.name, identifier: bundleID ?? "",
                                     newLimit: newLimit, verified: false)
            }
        }
        return matches
    }

    private static func scanRange(image: MachOImage, data: Data, start: UInt64, end: UInt64,
                                  functionName: String, identifier: String,
                                  newLimit: UInt8, verified: Bool) -> [PortLimitMatch] {
        guard let startOff = fileOffset(forVM: start, image: image) else { return [] }
        let span = Int(min(end - start, UInt64(4096)))
        guard span > 3, startOff + span <= data.count else { return [] }
        var out: [PortLimitMatch] = []
        let bytes = [UInt8](data[data.startIndex + startOff ..< data.startIndex + startOff + span])
        var p = 0
        while p + 3 < bytes.count {
            let rex = (bytes[p] >= 0x40 && bytes[p] <= 0x4F) ? 1 : 0
            guard p + rex + 2 < bytes.count else { break }
            if bytes[p + rex] == 0x83, bytes[p + rex + 1] >= 0xF8, bytes[p + rex + 2] == 0x0F {
                let winLen = min(windowLength, bytes.count - p)
                let find = Array(bytes[p ..< p + winLen])
                let immIndex = rex + 2
                if immIndex < find.count {
                    var replace = find
                    replace[immIndex] = newLimit
                    out.append(PortLimitMatch(functionName: functionName, identifier: identifier,
                        vmaddr: start + UInt64(p), fileOffset: startOff + p, immOffsetInWindow: immIndex,
                        find: find, replace: replace, newLimit: newLimit, verified: verified, origin: .binary))
                }
                p += rex + 3
                continue
            }
            p += 1
        }
        return out
    }

    static func fileOffset(forVM vm: UInt64, image: MachOImage) -> Int? {
        for sec in image.sections {
            guard sec.offset != 0, sec.size != 0 else { continue }
            if vm >= sec.addr && vm < sec.addr + sec.size {
                return image.sliceOffset + Int(sec.offset) + Int(vm - sec.addr)
            }
        }
        return nil
    }

    // MARK: - Live Kernel Collection scan (MH_FILESET)

    /// Reads the boot Kernel Collection, locates createPorts / setPortLocation
    /// in the real AppleUSBXHCI / IOUSBHostFamily code, and derives the patches
    /// for the running build. Returns matches + a diagnostic log.
    static func scanKernelCollection(path: String = bootKCPath,
                                     newLimit: UInt8 = 0x40) -> (matches: [PortLimitMatch], log: String) {
        var log = ""
        func note(_ s: String) { log += s + "\n" }

        guard let data = FileManager.default.contents(atPath: path) else {
            return ([], "Could not read \(path).\nThe app runs non-sandboxed, so this usually means the file is missing or unreadable on this system.")
        }
        note("Kernel Collection: \(path)  (\(data.count / (1024 * 1024)) MB)")

        guard rd32(data, 0) == 0xFEEDFACF else {
            return ([], "Not a 64-bit Mach-O (magic 0x\(String(rd32(data, 0), radix: 16))). On Apple Silicon this would be arm64e — the x86_64 patch doesn't apply there.")
        }

        typealias Seg = (UInt64, UInt64, UInt64, UInt64)   // vmaddr, vmsize, fileoff, filesize
        typealias Symtab = (Int, Int, Int, Int)            // symoff, nsyms, stroff, strsize

        func parse(_ base: Int) -> (segs: [Seg], symtab: Symtab?, filesets: [(String, UInt64, Int)]) {
            var segs: [Seg] = []; var symtab: Symtab? = nil; var filesets: [(String, UInt64, Int)] = []
            guard rd32(data, base) == 0xFEEDFACF else { return (segs, symtab, filesets) }
            let ncmds = Int(rd32(data, base + 16)); var o = base + 32
            for _ in 0..<ncmds {
                let c = rd32(data, o); let cs = Int(rd32(data, o + 4))
                if cs == 0 { break }
                switch c {
                case 0x19: segs.append((rd64(data, o+24), rd64(data, o+32), rd64(data, o+40), rd64(data, o+48)))
                case 0x2:  symtab = (Int(rd32(data, o+8)), Int(rd32(data, o+12)), Int(rd32(data, o+16)), Int(rd32(data, o+20)))
                case 0x80000035:
                    let vm = rd64(data, o+8); let fo = rd64(data, o+16); let idoff = Int(rd32(data, o+24))
                    filesets.append((cstr(data, o + idoff), vm, Int(fo)))
                default: break
                }
                o += cs
            }
            return (segs, symtab, filesets)
        }

        func vmoff(_ segs: [Seg], _ vm: UInt64) -> Int? {
            for (va, vs, fo, fs) in segs where vs != 0 && fs != 0 && vm >= va && vm < va + vs && vm - va < fs {
                return Int(fo + (vm - va))
            }
            return nil
        }

        func symbols(_ symtab: Symtab?, _ needle: String) -> [(String, UInt64)] {
            guard let (symoff, nsyms, stroff, _) = symtab else { return [] }
            var out: [(String, UInt64)] = []
            for i in 0..<nsyms {
                let e = symoff + i * 16
                if e + 16 > data.count { break }
                let v = rd64(data, e + 8)
                if v == 0 { continue }
                let nm = cstr(data, stroff + Int(rd32(data, e)))
                if nm.contains(needle) { out.append((nm, v)) }
            }
            return out
        }

        let kc = parse(0)
        note("fileset entries: \(kc.filesets.count)")
        var fsd: [String: (UInt64, Int)] = [:]
        for (i, vm, fo) in kc.filesets { fsd[i] = (vm, fo) }

        let targets = [("com.apple.driver.usb.AppleUSBXHCI", "createPorts"),
                       ("com.apple.iokit.IOUSBHostFamily", "setPortLocation")]
        var matches: [PortLimitMatch] = []

        for (ident, needle) in targets {
            var views: [(segs: [Seg], sym: Symtab?)] = []
            if let (_, fo) = fsd[ident] { let p = parse(fo); views.append((p.segs, p.symtab)) }
            views.append((kc.segs, kc.symtab))

            var found: (segs: [Seg], syms: [(String, UInt64)])? = nil
            outer: for v in views {
                for nd in [needle, "createPorts", "setPortLocation", "PortLimit"] {
                    let s = symbols(v.sym, nd)
                    if !s.isEmpty { found = (v.segs, s); break outer }
                }
            }
            guard let f = found else { note("\(ident): no matching symbol"); continue }

            var made = false
            for (nm, vm) in f.syms {
                guard let start = vmoff(f.segs, vm) ?? vmoff(kc.segs, vm) else { continue }
                if let m = scanBytesForCmp(data: data, start: start, newLimit: newLimit) {
                    matches.append(PortLimitMatch(functionName: nm, identifier: ident, vmaddr: vm,
                        fileOffset: start + m.rel, immOffsetInWindow: m.imm, find: m.find, replace: m.replace,
                        newLimit: newLimit, verified: true, origin: .kernelCollection))
                    note("\(ident): \(nm) @ vm 0x\(String(vm, radix: 16))")
                    made = true
                    break
                }
            }
            if !made { note("\(ident): symbol found but no cmp,0x0F nearby") }
        }
        return (matches, log)
    }

    private static func scanBytesForCmp(data: Data, start: Int, newLimit: UInt8)
        -> (find: [UInt8], replace: [UInt8], imm: Int, rel: Int)? {
        let end = min(start + 4096, data.count)
        let base = data.startIndex
        var p = start
        while p + 3 < end {
            let b0 = data[base + p]
            let rex = (b0 >= 0x40 && b0 <= 0x4F) ? 1 : 0
            if p + rex + 2 >= end { break }
            if data[base + p + rex] == 0x83, data[base + p + rex + 1] >= 0xF8, data[base + p + rex + 2] == 0x0F {
                let winLen = min(windowLength, end - p)
                let find = [UInt8](data[base + p ..< base + p + winLen])
                let ii = rex + 2
                var replace = find
                replace[ii] = newLimit
                return (find, replace, ii, p - start)
            }
            p += 1
        }
        return nil
    }

    // MARK: - Little-endian readers

    private static func rd32(_ d: Data, _ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= d.count else { return 0 }
        return d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }
    }
    private static func rd64(_ d: Data, _ o: Int) -> UInt64 {
        guard o >= 0, o + 8 <= d.count else { return 0 }
        return d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) }
    }
    private static func cstr(_ d: Data, _ o: Int) -> String {
        guard o >= 0, o < d.count else { return "" }
        let base = d.startIndex
        var end = o
        while end < d.count, d[base + end] != 0 { end += 1 }
        return String(decoding: d[base + o ..< base + end], as: UTF8.self)
    }
}

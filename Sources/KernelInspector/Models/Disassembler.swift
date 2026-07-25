import Foundation

/// Disassembles a Mach-O file by shelling out to the developer tools that ship
/// with Xcode / Command Line Tools: `otool -tvV` (preferred) or `llvm-objdump`.
///
/// This keeps the app dependency-free while producing real, correct output.
/// A native Capstone backend can be dropped in later (see README).
enum Disassembler {

    enum Backend: String, CaseIterable {
        case otool = "otool"
        case objdump = "llvm-objdump"
    }

    static func availableBackend() -> Backend? {
        for b in Backend.allCases where toolPath(b) != nil { return b }
        return nil
    }

    static func toolPath(_ b: Backend) -> String? {
        let candidates: [String]
        switch b {
        case .otool:
            candidates = ["/usr/bin/otool", "/usr/local/bin/otool"]
        case .objdump:
            candidates = ["/usr/bin/llvm-objdump",
                          "/Library/Developer/CommandLineTools/usr/bin/llvm-objdump",
                          "/usr/local/opt/llvm/bin/llvm-objdump"]
        }
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        // Fall back to `xcrun` resolution.
        if let resolved = xcrun(b.rawValue) { return resolved }
        return nil
    }

    private static func xcrun(_ tool: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["-f", tool]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Returns disassembled instructions for the __text section of `binaryURL`.
    static func disassemble(binaryURL: URL, arch: String) -> [Instruction] {
        guard let backend = availableBackend(), let tool = toolPath(backend) else { return [] }
        let args: [String]
        switch backend {
        case .otool:
            args = ["-arch", arch, "-tvV", binaryURL.path]
        case .objdump:
            args = ["--macho", "--arch=\(arch)", "-d", binaryURL.path]
        }
        guard let output = run(tool: tool, args: args) else { return [] }
        return backend == .otool ? parseOtool(output) : parseObjdump(output)
    }

    /// Fills the `bytes` column for instructions that don't already have it
    /// (otool -tvV omits raw bytes). Length is derived from the gap to the next
    /// instruction (ARM64 is always 4). Bytes are read from the file via the
    /// section map. Returns instructions sorted by address.
    static func fillBytes(_ insns: [Instruction], image: MachOImage, data: Data, arch: String) -> [Instruction] {
        guard !insns.isEmpty, !data.isEmpty else { return insns }
        let isARM = arch.lowercased().contains("arm")
        let sorted = insns.sorted { $0.address < $1.address }
        var out: [Instruction] = []
        out.reserveCapacity(sorted.count)
        for i in 0..<sorted.count {
            let ins = sorted[i]
            if !ins.bytes.isEmpty { out.append(ins); continue }   // objdump already provided them
            var length = 4
            if !isARM {
                if i + 1 < sorted.count {
                    let d = Int(sorted[i + 1].address) - Int(ins.address)
                    length = (d >= 1 && d <= 15) ? d : 0          // 0 = unknown (gap / last)
                } else {
                    length = 0
                }
            }
            var hex = ""
            if length > 0,
               let off = PortLimitScanner.fileOffset(forVM: ins.address, image: image),
               off >= 0, off + length <= data.count {
                let base = data.startIndex
                hex = data[base + off ..< base + off + length]
                    .map { String(format: "%02x", $0) }.joined(separator: " ")
            }
            out.append(Instruction(address: ins.address, bytes: hex,
                                   mnemonic: ins.mnemonic, operands: ins.operands))
        }
        return out
    }

    private static func run(tool: String, args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // otool -tvV lines look like:
    //   _symbol:
    //   0000000000001f80\tpacibsp
    //   0000000000001f84\tstp\tx29, x30, [sp, #-0x10]!
    private static func parseOtool(_ text: String) -> [Instruction] {
        var result: [Instruction] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasSuffix(":") { continue }                 // label
            if line.contains("(__TEXT") { continue }            // section banner
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }
            let addrStr = parts[0].trimmingCharacters(in: .whitespaces)
            guard let addr = UInt64(addrStr, radix: 16) else { continue }
            let mnemonic = parts[1].trimmingCharacters(in: .whitespaces)
            let operands = parts.count > 2
                ? parts[2...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
                : ""
            result.append(Instruction(address: addr, bytes: "", mnemonic: mnemonic, operands: operands))
        }
        return result
    }

    // llvm-objdump lines look like:
    //   0000000000001f80 <_symbol>:
    //     1f80: fd 7b bf a9 \tstp\tx29, x30, [sp, #-0x10]!
    private static func parseObjdump(_ text: String) -> [Instruction] {
        var result: [Instruction] = []
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let addrPart = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard let addr = UInt64(addrPart, radix: 16) else { continue }
            let rest = String(line[line.index(after: colon)...])
            // Separate the byte column (before the tab) from the mnemonic.
            let comps = rest.components(separatedBy: "\t")
            let insnField = comps.count > 1 ? comps[1...].joined(separator: " ") : rest
            let tokens = insnField.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 1).map(String.init)
            let mnemonic = tokens.first ?? ""
            let operands = tokens.count > 1 ? tokens[1] : ""
            let bytes = comps.first?.trimmingCharacters(in: .whitespaces) ?? ""
            if mnemonic.isEmpty { continue }
            result.append(Instruction(address: addr, bytes: bytes, mnemonic: mnemonic, operands: operands))
        }
        return result
    }
}

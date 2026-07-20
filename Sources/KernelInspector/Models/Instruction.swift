import Foundation

struct Instruction: Identifiable {
    let id = UUID()
    let address: UInt64
    let bytes: String       // raw bytes column when available
    let mnemonic: String
    let operands: String

    var text: String { operands.isEmpty ? mnemonic : "\(mnemonic)\t\(operands)" }

    // --- Flow analysis helpers (ARM64 + x86 heuristics) ---

    var isReturn: Bool {
        let m = mnemonic.lowercased()
        return m == "ret" || m == "retab" || m == "retaa" || m.hasPrefix("ret")
    }

    var isUnconditionalBranch: Bool {
        let m = mnemonic.lowercased()
        return m == "b" || m == "br" || m == "jmp" || m == "braa" || m == "brab"
    }

    var isConditionalBranch: Bool {
        let m = mnemonic.lowercased()
        if m.hasPrefix("b.") { return true }                 // ARM64 b.eq etc.
        if ["cbz","cbnz","tbz","tbnz"].contains(m) { return true }
        if m.hasPrefix("j") && m != "jmp" { return true }    // x86 jcc
        return false
    }

    var isCall: Bool {
        let m = mnemonic.lowercased()
        return m == "bl" || m == "blr" || m == "call" || m == "blraa"
    }

    var isBranch: Bool { isUnconditionalBranch || isConditionalBranch }

    /// Extract a branch target address from the operands, if it is an absolute hex.
    var branchTarget: UInt64? {
        guard isBranch else { return nil }
        // Look for a 0x… token in the operands.
        for token in operands.split(whereSeparator: { " ,\t".contains($0) }) {
            let t = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            if t.hasPrefix("0x"), let v = UInt64(t.dropFirst(2), radix: 16) {
                return v
            }
        }
        return nil
    }
}

import Foundation

/// Experimental, best-effort pseudo-C rendering of a function's basic blocks.
///
/// This is intentionally simple: it labels blocks, turns conditional branches
/// into `if (cond) goto loc_x;` and unconditional branches into `goto`.
/// It is meant as a readability aid, not a true decompiler.
enum Pseudocode {

    static func render(blocks: [BasicBlock], functionName: String) -> String {
        guard !blocks.isEmpty else { return "// no code" }
        var out = "// Experimental pseudocode — heuristic, not a real decompiler\n"
        out += "void \(sanitize(functionName))(void) {\n"
        for block in blocks {
            out += "\n\(block.label):\n"
            for ins in block.instructions {
                out += "    " + line(for: ins) + "\n"
            }
        }
        out += "}\n"
        return out
    }

    private static func line(for ins: Instruction) -> String {
        let m = ins.mnemonic.lowercased()
        if ins.isReturn { return "return;" }
        if ins.isCall {
            return "call \(ins.operands);"
        }
        if ins.isUnconditionalBranch {
            if let t = ins.branchTarget { return String(format: "goto loc_%llx;", t) }
            return "goto \(ins.operands);"
        }
        if ins.isConditionalBranch {
            let cond = conditionText(m)
            if let t = ins.branchTarget {
                return String(format: "if (%@) goto loc_%llx;   // %@ %@", cond, t, ins.mnemonic, ins.operands)
            }
            return "if (\(cond)) goto \(ins.operands);"
        }
        // Fallback: keep the assembly as a commented statement.
        return "\(ins.mnemonic) \(ins.operands);".trimmingCharacters(in: .whitespaces)
    }

    private static func conditionText(_ m: String) -> String {
        switch m {
        case "cbz":  return "x == 0"
        case "cbnz": return "x != 0"
        case "tbz":  return "!bit"
        case "tbnz": return "bit"
        case "b.eq", "je":  return "=="
        case "b.ne", "jne": return "!="
        case "b.lt", "jl":  return "<"
        case "b.gt", "jg":  return ">"
        case "b.le", "jle": return "<="
        case "b.ge", "jge": return ">="
        default: return m.replacingOccurrences(of: "b.", with: "cc_")
        }
    }

    private static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        var s = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        if let first = s.first, first.isNumber { s = "_" + s }
        return s.isEmpty ? "sub_func" : s
    }
}

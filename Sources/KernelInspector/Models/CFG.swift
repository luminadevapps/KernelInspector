import Foundation

/// A basic block: a straight-line run of instructions with a single entry.
struct BasicBlock: Identifiable {
    let id = UUID()
    let start: UInt64
    var instructions: [Instruction]
    var successors: [UInt64]      // addresses of successor blocks

    var label: String { String(format: "loc_%llx", start) }
}

/// Builds a control-flow graph from a flat instruction list by splitting at
/// branch targets and after terminators. Works for ARM64 & x86 heuristically.
enum CFGBuilder {

    static func build(from insns: [Instruction]) -> [BasicBlock] {
        guard !insns.isEmpty else { return [] }
        let sorted = insns.sorted { $0.address < $1.address }
        let addrSet = Set(sorted.map { $0.address })

        // 1. Determine leaders (block-start addresses).
        var leaders = Set<UInt64>()
        leaders.insert(sorted[0].address)
        for (i, ins) in sorted.enumerated() {
            if ins.isBranch, let target = ins.branchTarget, addrSet.contains(target) {
                leaders.insert(target)
            }
            // Instruction following a branch/return starts a new block.
            if ins.isBranch || ins.isReturn {
                if i + 1 < sorted.count { leaders.insert(sorted[i + 1].address) }
            }
        }

        // 2. Slice into blocks.
        var blocks: [BasicBlock] = []
        var current: [Instruction] = []
        var currentStart: UInt64 = sorted[0].address

        func flush(nextLeaderFallthrough: UInt64?) {
            guard let last = current.last else { return }
            var succ: [UInt64] = []
            if last.isReturn {
                // no successors
            } else if last.isUnconditionalBranch {
                if let t = last.branchTarget, addrSet.contains(t) { succ.append(t) }
            } else if last.isConditionalBranch {
                if let t = last.branchTarget, addrSet.contains(t) { succ.append(t) }
                if let f = nextLeaderFallthrough { succ.append(f) }
            } else {
                if let f = nextLeaderFallthrough { succ.append(f) }
            }
            blocks.append(BasicBlock(start: currentStart, instructions: current, successors: succ))
            current = []
        }

        for (i, ins) in sorted.enumerated() {
            if leaders.contains(ins.address) && !current.isEmpty {
                flush(nextLeaderFallthrough: ins.address)
                currentStart = ins.address
            }
            if current.isEmpty { currentStart = ins.address }
            current.append(ins)
            let next = (i + 1 < sorted.count) ? sorted[i + 1].address : nil
            let boundary = ins.isBranch || ins.isReturn ||
                (next != nil && leaders.contains(next!))
            if boundary {
                flush(nextLeaderFallthrough: next)
            }
        }
        flush(nextLeaderFallthrough: nil)
        return blocks
    }
}

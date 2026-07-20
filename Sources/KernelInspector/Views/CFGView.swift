import SwiftUI

struct CFGView: View {
    @EnvironmentObject var doc: DocumentModel
    @State private var selection: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            FunctionPicker(selection: $selection)
            Divider()
            if blocks.isEmpty {
                ContentUnavailable("No control flow",
                    detail: "Disassemble a function first, or pick another symbol.")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(blocks) { block in
                            BlockCard(block: block, allBlocks: blocks)
                        }
                    }
                    .padding()
                }
            }
        }
    }

    private var blocks: [BasicBlock] {
        let funcs = doc.functions()
        guard funcs.indices.contains(selection) else { return [] }
        return CFGBuilder.build(from: funcs[selection].insns)
    }
}

struct BlockCard: View {
    let block: BasicBlock
    let allBlocks: [BasicBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(block.label)
                .font(.caption.monospaced().bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.accentColor).clipShape(Capsule())
            ForEach(block.instructions) { ins in
                HStack(spacing: 10) {
                    Text(String(format: "%08llX", ins.address)).foregroundStyle(.secondary)
                    Text(ins.mnemonic).foregroundStyle(flowColor(ins)).frame(width: 80, alignment: .leading)
                    Text(ins.operands)
                }
                .font(.system(.callout, design: .monospaced))
            }
            if !block.successors.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                    ForEach(block.successors, id: \.self) { s in
                        Text(String(format: "loc_%llx", s))
                            .font(.caption.monospaced())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.25)))
    }

    private func flowColor(_ ins: Instruction) -> Color {
        if ins.isReturn { return .red }
        if ins.isCall { return .purple }
        if ins.isBranch { return .orange }
        return .primary
    }
}

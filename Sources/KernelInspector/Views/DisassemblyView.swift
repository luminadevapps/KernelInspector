import SwiftUI

struct DisassemblyView: View {
    @EnvironmentObject var doc: DocumentModel
    @State private var filter: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter by mnemonic or operand", text: $filter)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                Button {
                    doc.disassemble()
                } label: { Label("Re-run", systemImage: "arrow.clockwise") }
                Text("\(doc.instructions.count) insns").font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            if doc.isDisassembling {
                ProgressView("Disassembling…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if doc.instructions.isEmpty {
                ContentUnavailable("No disassembly",
                    detail: "Backend: \(doc.backendName). Ensure Xcode Command Line Tools are installed (xcode-select --install).")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filtered) { ins in
                            HStack(alignment: .top, spacing: 12) {
                                Text(String(format: "0x%08llX", ins.address))
                                    .foregroundStyle(.secondary)
                                Text(ins.mnemonic)
                                    .foregroundStyle(color(for: ins)).frame(width: 90, alignment: .leading)
                                Text(ins.operands).textSelection(.enabled)
                                Spacer()
                            }
                            .font(.system(.body, design: .monospaced))
                            .padding(.vertical, 1)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
        }
    }

    private var filtered: [Instruction] {
        guard !filter.isEmpty else { return doc.instructions }
        return doc.instructions.filter {
            $0.mnemonic.localizedCaseInsensitiveContains(filter) ||
            $0.operands.localizedCaseInsensitiveContains(filter)
        }
    }

    private func color(for ins: Instruction) -> Color {
        if ins.isReturn { return .red }
        if ins.isCall { return .purple }
        if ins.isBranch { return .orange }
        return .primary
    }
}

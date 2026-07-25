import SwiftUI

struct DisassemblyView: View {
    @EnvironmentObject var doc: DocumentModel
    @State private var filter: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter by mnemonic, operand, or hex bytes", text: $filter)
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
                // Column header (address | hex bytes | instruction)
                HStack(alignment: .top, spacing: 12) {
                    Text("Address").frame(width: 92, alignment: .leading)
                    Text("Hex").frame(width: 150, alignment: .leading)
                    Text("Instruction")
                    Spacer()
                }
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.bar)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filtered) { ins in
                            HStack(alignment: .top, spacing: 12) {
                                Text(String(format: "0x%08llX", ins.address))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 92, alignment: .leading)
                                Text(ins.bytes.isEmpty ? "—" : ins.bytes)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 150, alignment: .leading)
                                    .lineLimit(1).truncationMode(.tail)
                                    .textSelection(.enabled)
                                    .help(ins.bytes)
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
            $0.operands.localizedCaseInsensitiveContains(filter) ||
            $0.bytes.localizedCaseInsensitiveContains(filter)
        }
    }

    private func color(for ins: Instruction) -> Color {
        if ins.isReturn { return .red }
        if ins.isCall { return .purple }
        if ins.isBranch { return .orange }
        return .primary
    }
}

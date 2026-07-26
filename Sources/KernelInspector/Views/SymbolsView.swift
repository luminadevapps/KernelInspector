import SwiftUI

struct SymbolsView: View {
    @EnvironmentObject var doc: DocumentModel
    @State private var filter: String = ""
    @State private var kind: String = "all"
    @State private var selection: Symbol.ID?

    private var kinds: [String] { ["all", "global", "local", "undefined", "debug"] }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter symbols", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $kind) {
                    ForEach(kinds, id: \.self) { Text($0.capitalized).tag($0) }
                }.pickerStyle(.segmented).frame(width: 360)
            }
            .padding([.horizontal, .top])
            Text("Click a symbol to jump to it in the Disassembly view.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal).padding(.bottom, 8)
            Divider()
            Table(filtered, selection: $selection) {
                TableColumn("Address") {
                    Text($0.value == 0 ? "—" : String(format: "0x%llX", $0.value))
                        .font(.system(.body, design: .monospaced))
                }.width(140)
                TableColumn("Kind") { Text($0.kind).foregroundStyle(color(for: $0.kind)) }.width(90)
                TableColumn("Symbol") {
                    Text($0.name).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            }
            .onChange(of: selection) { _, id in jump(to: id) }
        }
    }

    /// A row was selected — jump to that symbol's address in Disassembly.
    /// Undefined symbols (value 0) have no code to show, so they're ignored.
    private func jump(to id: Symbol.ID?) {
        guard let id, let sym = filtered.first(where: { $0.id == id }), sym.value != 0 else { return }
        doc.pendingDisassemblyAddress = sym.value
        doc.paneRequest = .disassembly
        // Reset so the same row can be clicked again after coming back.
        selection = nil
    }

    private var filtered: [Symbol] {
        guard let syms = doc.image?.symbols else { return [] }
        return syms.filter { s in
            (kind == "all" || s.kind == kind) &&
            (filter.isEmpty || s.name.localizedCaseInsensitiveContains(filter))
        }
    }

    private func color(for kind: String) -> Color {
        switch kind {
        case "global": return .green
        case "local": return .blue
        case "undefined": return .orange
        case "debug": return .secondary
        default: return .primary
        }
    }
}

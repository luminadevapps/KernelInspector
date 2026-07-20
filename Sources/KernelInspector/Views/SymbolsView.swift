import SwiftUI

struct SymbolsView: View {
    @EnvironmentObject var doc: DocumentModel
    @State private var filter: String = ""
    @State private var kind: String = "all"

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
            .padding()
            Divider()
            Table(filtered) {
                TableColumn("Address") {
                    Text($0.value == 0 ? "—" : String(format: "0x%llX", $0.value))
                        .font(.system(.body, design: .monospaced))
                }.width(140)
                TableColumn("Kind") { Text($0.kind).foregroundStyle(color(for: $0.kind)) }.width(90)
                TableColumn("Symbol") {
                    Text($0.name).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
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

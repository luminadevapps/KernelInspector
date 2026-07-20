import SwiftUI

/// Shared control for choosing which function (symbol) to analyse.
///
/// A large kext can have *thousands* of functions. A plain `Picker` renders
/// every item eagerly, which freezes the UI. So we filter by name and cap the
/// menu to a small number of matches — the render stays cheap no matter how
/// many functions the binary has.
struct FunctionPicker: View {
    @EnvironmentObject var doc: DocumentModel
    @Binding var selection: Int
    @State private var query = ""

    private let maxItems = 200

    private var funcs: [(symbol: Symbol, insns: [Instruction])] { doc.functions() }

    /// Indices (into `funcs`) that match the query, capped for performance.
    private var matches: [Int] {
        let all = funcs
        let idxs: [Int]
        if query.isEmpty {
            idxs = Array(all.indices)
        } else {
            idxs = all.indices.filter { all[$0].symbol.name.localizedCaseInsensitiveContains(query) }
        }
        // Always keep the current selection visible so the Picker shows a label.
        var capped = Array(idxs.prefix(maxItems))
        if !capped.contains(selection), all.indices.contains(selection) {
            capped.insert(selection, at: 0)
        }
        return capped
    }

    var body: some View {
        HStack(spacing: 10) {
            TextField("Filter functions…", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)

            Picker("", selection: $selection) {
                ForEach(matches, id: \.self) { idx in
                    Text("\(funcs[idx].symbol.name)  (\(funcs[idx].insns.count))").tag(idx)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 460)

            if funcs.indices.contains(selection) {
                Text(String(format: "0x%llX", funcs[selection].symbol.value))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(funcs.count) funcs")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear { if !funcs.indices.contains(selection) { selection = 0 } }
    }
}

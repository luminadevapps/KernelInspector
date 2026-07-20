import SwiftUI

struct PseudocodeView: View {
    @EnvironmentObject var doc: DocumentModel
    @State private var selection: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            FunctionPicker(selection: $selection)
            Divider()
            ScrollView {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    private var code: String {
        let funcs = doc.functions()
        guard funcs.indices.contains(selection) else { return "// select a function" }
        let f = funcs[selection]
        let blocks = CFGBuilder.build(from: f.insns)
        return Pseudocode.render(blocks: blocks, functionName: f.symbol.name)
    }
}

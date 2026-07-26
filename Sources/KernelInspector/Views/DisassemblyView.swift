import SwiftUI

struct DisassemblyView: View {
    @EnvironmentObject var doc: DocumentModel
    @State private var filter: String = ""
    // "Go to" state: the query, the row we jumped to (for highlight), and a
    // short status message shown next to the field.
    @State private var gotoText: String = ""
    @State private var landedID: Instruction.ID?
    @State private var gotoMessage: String?
    @State private var gotoFailed = false

    var body: some View {
        // ScrollViewReader wraps the whole pane so the toolbar's "Go" button can
        // drive the instruction list's scroll position via the proxy.
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                toolbar(proxy)
                Divider()
                instructionList(proxy)
            }
            // Honour a jump requested from another pane (e.g. clicking a symbol).
            .onAppear { consumePendingJump(proxy) }
            .onChange(of: doc.pendingDisassemblyAddress) { _, _ in consumePendingJump(proxy) }
        }
    }

    /// If another pane queued an address to jump to, scroll there once the list
    /// has laid out, then clear the request so it only fires once.
    private func consumePendingJump(_ proxy: ScrollViewProxy) {
        guard let addr = doc.pendingDisassemblyAddress else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let ins = nearestInstruction(to: addr) { scrollTo(ins, proxy) }
            doc.pendingDisassemblyAddress = nil
        }
    }

    // MARK: Toolbar

    @ViewBuilder
    private func toolbar(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(.secondary)
                    .help("Filter — hides rows that don't match. To jump to an address, use the Go to field below.")
                TextField("Filter shown rows (mnemonic, operand, hex bytes)", text: $filter)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                Button {
                    doc.disassemble()
                } label: { Label("Re-run", systemImage: "arrow.clockwise") }
                Text("\(doc.instructions.count) insns").font(.caption).foregroundStyle(.secondary)
            }

            // Go to address (0x…) or a function's start by name.
            HStack(spacing: 8) {
                Image(systemName: "arrow.right.to.line").foregroundStyle(.secondary)
                TextField("Go to address (0x1234) or function name", text: $gotoText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: 320)
                    .onSubmit { performGoto(proxy) }
                Button {
                    performGoto(proxy)
                } label: { Label("Go", systemImage: "location.magnifyingglass") }
                    .disabled(gotoText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut("g", modifiers: .command)
                if let m = gotoMessage {
                    Text(m)
                        .font(.caption.monospaced())
                        .foregroundStyle(gotoFailed ? Color.red : .secondary)
                }
                Spacer()
            }
        }
        .padding()
    }

    // MARK: List

    @ViewBuilder
    private func instructionList(_ proxy: ScrollViewProxy) -> some View {
        if doc.isDisassembling {
            ProgressView("Disassembling…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if doc.instructions.isEmpty {
            ContentUnavailable("No disassembly",
                detail: "Backend: \(doc.backendName). Ensure Xcode Command Line Tools are installed (xcode-select --install).")
        } else {
            header
            Divider()
            if filtered.isEmpty {
                // The filter hid every row. This is the exact spot people land
                // when they type an address into the filter by mistake — so say
                // so, and point them at the right field.
                VStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("No instructions match the filter “\(filter)”.")
                        .foregroundStyle(.secondary)
                    if looksLikeAddress(filter) {
                        Text("That looks like an address — use the “Go to” field (with the ⇥ arrow), not the filter.")
                            .font(.callout).foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }
                    Button("Clear filter") { filter = "" }.buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filtered) { ins in
                            row(ins)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
        }
    }

    /// Heuristic: does this filter text look like the user meant to jump to an
    /// address (e.g. "0x3EB0" or bare hex) rather than filter rows?
    private func looksLikeAddress(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { return true }
        return t.count >= 3 && t.allSatisfy { $0.isHexDigit }
    }

    private var header: some View {
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
    }

    @ViewBuilder
    private func row(_ ins: Instruction) -> some View {
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
        .padding(.horizontal, 4)
        // Highlight the row we jumped to so it's obvious where "Go" landed.
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(ins.id == landedID ? Color.accentColor.opacity(0.25) : Color.clear))
        .id(ins.id)
    }

    // MARK: Go to

    /// Resolve the query to an address (or a function's start) and scroll there.
    private func performGoto(_ proxy: ScrollViewProxy) {
        let raw = gotoText.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !doc.instructions.isEmpty else { return }

        // 0x-prefixed → address. Otherwise try a function name first (so a symbol
        // called "start" wins over being read as hex), then fall back to bare hex.
        var addr: UInt64?
        if raw.lowercased().hasPrefix("0x") {
            addr = parseHex(raw)
        } else if let sym = matchFunction(raw) {
            addr = sym.value
        } else {
            addr = parseHex(raw)
        }

        guard let target = addr, let ins = nearestInstruction(to: target) else {
            gotoFailed = true
            gotoMessage = "No match"
            landedID = nil
            return
        }
        scrollTo(ins, proxy)
    }

    /// Scroll to and highlight an instruction, clearing any filter that hides it.
    private func scrollTo(_ ins: Instruction, _ proxy: ScrollViewProxy) {
        if !filtered.contains(where: { $0.id == ins.id }) { filter = "" }
        landedID = ins.id
        gotoFailed = false
        gotoMessage = String(format: "→ 0x%08llX", ins.address)
        withAnimation { proxy.scrollTo(ins.id, anchor: .top) }
    }

    /// Parse a hex address with or without a `0x` prefix. Returns nil if the
    /// string isn't valid hex (e.g. it's a function name).
    private func parseHex(_ s: String) -> UInt64? {
        var t = s.lowercased()
        if t.hasPrefix("0x") { t = String(t.dropFirst(2)) }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        guard !t.isEmpty else { return nil }
        return UInt64(t, radix: 16)
    }

    /// Find a function symbol by name — exact match first, then substring.
    private func matchFunction(_ q: String) -> Symbol? {
        let fs = doc.functions()
        if let exact = fs.first(where: { $0.symbol.name.caseInsensitiveCompare(q) == .orderedSame }) {
            return exact.symbol
        }
        return fs.first { $0.symbol.name.localizedCaseInsensitiveContains(q) }?.symbol
    }

    /// The instruction at `addr`, or the first one after it (so a mid-function
    /// address still lands somewhere sensible). Falls back to the last row.
    private func nearestInstruction(to addr: UInt64) -> Instruction? {
        let sorted = doc.instructions.sorted { $0.address < $1.address }
        if let exact = sorted.first(where: { $0.address == addr }) { return exact }
        return sorted.first(where: { $0.address >= addr }) ?? sorted.last
    }

    // MARK: Filtering / colour

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

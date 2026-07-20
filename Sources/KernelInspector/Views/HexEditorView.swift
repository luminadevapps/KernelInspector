import SwiftUI

struct HexEditorView: View {
    @EnvironmentObject var doc: DocumentModel
    @State private var findHex: String = ""
    @State private var replaceHex: String = ""
    @State private var matches: [Int] = []
    @State private var matchIndex: Int = 0
    @State private var errorText: String?

    private let bytesPerRow = 16

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            hexDump
        }
    }

    // MARK: Search bar

    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Find hex (e.g. DE AD BE EF)", text: $findHex)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    .onSubmit(runSearch)
                Button("Find", action: runSearch)
                Button("Prev") { step(-1) }.disabled(matches.isEmpty)
                Button("Next") { step(1) }.disabled(matches.isEmpty)
                if !matches.isEmpty {
                    Text("\(matchIndex + 1)/\(matches.count)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("Replace with hex", text: $replaceHex)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                Button("Replace") { replaceCurrent() }
                    .disabled(matches.isEmpty || replaceHex.isEmpty)
                Button("Replace All") { replaceAll() }
                    .disabled(matches.isEmpty || replaceHex.isEmpty)
            }
            if let e = errorText {
                Text(e).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }

    // MARK: Hex dump

    private var hexDump: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rowIndices, id: \.self) { row in
                        HexRow(row: row, data: doc.fileData,
                               bytesPerRow: bytesPerRow,
                               highlight: currentMatchRange)
                            .id(row)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .font(.system(.body, design: .monospaced))
            .onChange(of: matchIndex) { _ in scrollToMatch(proxy) }
        }
    }

    private var rowIndices: [Int] {
        let count = (doc.fileData.count + bytesPerRow - 1) / bytesPerRow
        // Cap rows rendered for very large files; LazyVStack keeps it cheap anyway.
        return Array(0..<count)
    }

    private var currentMatchRange: Range<Int>? {
        guard !matches.isEmpty else { return nil }
        let start = matches[matchIndex]
        let len = parseHex(findHex)?.count ?? 0
        guard len > 0 else { return nil }
        return start..<(start + len)
    }

    // MARK: Actions

    private func runSearch() {
        errorText = nil
        guard let pattern = parseHex(findHex), !pattern.isEmpty else {
            errorText = "Enter valid hex bytes, e.g. 55 48 89 E5"
            matches = []; return
        }
        matches = search(pattern: pattern, in: doc.fileData)
        matchIndex = 0
        if matches.isEmpty { errorText = "No matches found." }
    }

    private func step(_ dir: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + dir + matches.count) % matches.count
    }

    private func replaceCurrent() {
        guard let repl = parseHex(replaceHex), !repl.isEmpty else {
            errorText = "Replacement must be valid hex."; return
        }
        guard let find = parseHex(findHex), find.count == repl.count else {
            errorText = "Replacement must be the same length as the search (\(parseHex(findHex)?.count ?? 0) bytes)."
            return
        }
        guard !matches.isEmpty else { return }
        doc.patch(offset: matches[matchIndex], bytes: repl)
        runSearch()   // refresh match list
    }

    private func replaceAll() {
        guard let repl = parseHex(replaceHex),
              let find = parseHex(findHex), find.count == repl.count, !repl.isEmpty else {
            errorText = "Replacement must be valid hex of the same length as the search."
            return
        }
        // Apply from the end backwards so offsets stay valid (equal length anyway).
        for off in matches.reversed() { doc.patch(offset: off, bytes: repl) }
        runSearch()
    }

    private func scrollToMatch(_ proxy: ScrollViewProxy) {
        guard !matches.isEmpty else { return }
        let row = matches[matchIndex] / bytesPerRow
        withAnimation { proxy.scrollTo(row, anchor: .center) }
    }

    // MARK: Hex helpers

    private func parseHex(_ s: String) -> [UInt8]? {
        let cleaned = s.replacingOccurrences(of: "0x", with: "")
            .components(separatedBy: CharacterSet(charactersIn: " ,\t\n"))
            .joined()
        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let b = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
            out.append(b); idx = next
        }
        return out
    }

    private func search(pattern: [UInt8], in data: Data) -> [Int] {
        var result: [Int] = []
        guard pattern.count <= data.count else { return result }
        let n = data.count, m = pattern.count
        let base = data.startIndex
        var i = 0
        while i <= n - m {
            var j = 0
            while j < m && data[base + i + j] == pattern[j] { j += 1 }
            if j == m { result.append(i) }
            i += 1
        }
        return result
    }
}

/// One 16-byte row: offset | hex bytes | ASCII.
struct HexRow: View {
    let row: Int
    let data: Data
    let bytesPerRow: Int
    let highlight: Range<Int>?

    var body: some View {
        let start = row * bytesPerRow
        let end = min(start + bytesPerRow, data.count)
        HStack(alignment: .top, spacing: 12) {
            Text(String(format: "%08X", start))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(start..<start + bytesPerRow, id: \.self) { i in
                    if i < end {
                        Text(String(format: "%02X", data[data.startIndex + i]))
                            .foregroundStyle(isHighlighted(i) ? Color.white : Color.primary)
                            .background(isHighlighted(i) ? Color.accentColor : Color.clear)
                    } else {
                        Text("  ").foregroundStyle(.clear)
                    }
                }
            }
            Text(ascii(start, end))
                .foregroundStyle(.secondary)
        }
    }

    private func isHighlighted(_ i: Int) -> Bool {
        guard let h = highlight else { return false }
        return h.contains(i)
    }

    private func ascii(_ start: Int, _ end: Int) -> String {
        var s = ""
        for i in start..<end {
            let b = data[data.startIndex + i]
            s.append((b >= 0x20 && b < 0x7f) ? Character(UnicodeScalar(b)) : ".")
        }
        return s
    }
}

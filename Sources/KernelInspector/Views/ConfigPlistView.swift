import SwiftUI

/// Read-only viewer for an OpenCore config.plist: a kext summary plus the full
/// flattened, searchable key/value tree. Hands off to an external editor for
/// changes (editing OpenCore config in place is intentionally out of scope).
struct ConfigPlistView: View {
    let path: String
    @Environment(\.dismiss) private var dismiss

    @State private var kexts: [ConfigKext] = []
    @State private var rows: [PlistRow] = []
    @State private var filter = ""
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let err = loadError {
                ContentUnavailable("Could not read config.plist", detail: err)
            } else {
                content
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape.2").font(.title2).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("OpenCore config.plist").font(.headline)
                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { Maintenance.openExternally(path) } label: { Label("Open in Editor", systemImage: "square.and.pencil") }
            Button { Maintenance.reveal(path) } label: { Label("Reveal", systemImage: "folder") }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !kexts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Kernel → Add  (\(kexts.filter { $0.enabled }.count) enabled / \(kexts.count))")
                        .font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(kexts) { k in
                                HStack(spacing: 8) {
                                    Image(systemName: k.enabled ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(k.enabled ? .green : .secondary)
                                    Text(k.name).font(.system(.callout, design: .monospaced))
                                        .foregroundStyle(k.enabled ? .primary : .secondary)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
                .padding(12)
                Divider()
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter keys or values", text: $filter).textFieldStyle(.roundedBorder)
            }
            .padding(12)
            Table(filteredRows) {
                TableColumn("Key") { Text($0.key).font(.system(.caption, design: .monospaced)) }
                TableColumn("Value") { Text($0.value).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            }
        }
    }

    private var filteredRows: [PlistRow] {
        guard !filter.isEmpty else { return rows }
        return rows.filter {
            $0.key.localizedCaseInsensitiveContains(filter) ||
            $0.value.localizedCaseInsensitiveContains(filter)
        }
    }

    private func load() {
        guard let plist = Maintenance.loadPlist(path) else {
            loadError = "The file could not be parsed as a property list."
            return
        }
        kexts = Maintenance.configKexts(plist).map { ConfigKext(name: $0.name, enabled: $0.enabled) }
        rows = KextTarget.flatten(plist).sorted { $0.0 < $1.0 }.map { PlistRow(key: $0.0, value: $0.1) }
    }
}

struct ConfigKext: Identifiable {
    let id = UUID()
    let name: String
    let enabled: Bool
}

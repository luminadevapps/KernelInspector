import SwiftUI

struct InfoPlistView: View {
    @EnvironmentObject var doc: DocumentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let rows = doc.target?.plistRows, !rows.isEmpty {
                Table(rows.map { PlistRow(key: $0.0, value: $0.1) }) {
                    TableColumn("Key") { Text($0.key).font(.system(.body, design: .monospaced)) }
                    TableColumn("Value") { Text($0.value).textSelection(.enabled) }
                }
            } else {
                ContentUnavailable("No Info.plist",
                    detail: doc.target?.isBundle == true
                        ? "This bundle has no readable Info.plist."
                        : "This is a lone binary — open a .kext bundle to see its Info.plist.")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(doc.target?.displayName ?? "").font(.title2.bold())
            HStack(spacing: 16) {
                metaChip("Identifier", doc.target?.bundleIdentifier ?? "—")
                metaChip("Version", doc.target?.bundleVersion ?? "—")
                metaChip("Arch", doc.image?.arch ?? "—")
                metaChip("Type", doc.image?.fileType ?? "—")
            }
            if let uuid = doc.image?.uuid, !uuid.isEmpty {
                Text("UUID \(uuid)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let deps = doc.image?.dependencies, !deps.isEmpty {
                Text("Linked libraries: \(deps.count)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func metaChip(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospaced())
        }
    }
}

struct PlistRow: Identifiable {
    let id = UUID(); let key: String; let value: String
}

/// Tiny compatibility shim so the app builds on macOS 13 (ContentUnavailableView is 14+).
struct ContentUnavailable: View {
    let title: String; let detail: String
    init(_ title: String, detail: String) { self.title = title; self.detail = detail }
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

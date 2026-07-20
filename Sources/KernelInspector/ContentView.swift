import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case info = "Info.plist"
    case hex = "Hex Editor"
    case symbols = "Symbols"
    case disassembly = "Disassembly"
    case cfg = "Control Flow"
    case pseudocode = "Pseudocode"
    case installKexts = "Install Kexts"
    case maintenance = "Maintenance"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .info: return "doc.text"
        case .hex: return "number"
        case .symbols: return "tag"
        case .disassembly: return "chevron.left.forwardslash.chevron.right"
        case .cfg: return "point.3.connected.trianglepath.dotted"
        case .pseudocode: return "curlybraces"
        case .installKexts: return "square.and.arrow.down.on.square"
        case .maintenance: return "wrench.and.screwdriver"
        }
    }

    /// Panes that work without a loaded binary (system tools).
    var needsBinary: Bool { self != .installKexts && self != .maintenance }
}

/// Sidebar grouping.
enum PaneGroup: String, CaseIterable, Identifiable {
    case analyze = "Analyze"
    case system = "System"
    var id: String { rawValue }
    var panes: [Pane] {
        switch self {
        case .analyze: return [.info, .hex, .symbols, .disassembly, .cfg, .pseudocode]
        case .system:  return [.installKexts, .maintenance]
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var doc: DocumentModel
    @State private var pane: Pane? = .info

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    if let logo = AppLogo.image {
                        logo.resizable().aspectRatio(contentMode: .fit)
                            .frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Text("Kernel Inspector").font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
                List(selection: $pane) {
                    ForEach(PaneGroup.allCases) { group in
                        Section(group.rawValue) {
                            ForEach(group.panes) { p in
                                Label(p.rawValue, systemImage: p.icon).tag(p)
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            Group {
                let current = pane ?? .info
                if !current.needsBinary {
                    switch current {
                    case .installKexts: InstallKextsView()
                    case .maintenance:  MaintenanceView()
                    default:            EmptyStateView()
                    }
                } else if doc.isLoaded {
                    switch current {
                    case .info:        InfoPlistView()
                    case .hex:         HexEditorView()
                    case .symbols:     SymbolsView()
                    case .disassembly: DisassemblyView()
                    case .cfg:         CFGView()
                    case .pseudocode:  PseudocodeView()
                    case .installKexts: InstallKextsView()
                    case .maintenance:  MaintenanceView()
                    }
                } else {
                    EmptyStateView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    doc.openPanel()
                } label: { Label("Open", systemImage: "folder") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    doc.saveAsPanel()
                } label: { Label("Save Patched", systemImage: "square.and.arrow.down") }
                .disabled(!doc.isLoaded)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    doc.reset()
                } label: { Label("Close", systemImage: "xmark.circle") }
                .disabled(!doc.isLoaded)
                .help("Close the loaded binary and return to the welcome screen")
            }
        }
        .safeAreaInset(edge: .bottom) {
            StatusBar()
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject var doc: DocumentModel
    var body: some View {
        HStack(spacing: 10) {
            if doc.isDisassembling { ProgressView().controlSize(.small) }
            Text(doc.status).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let img = doc.image {
                Text("\(img.arch) · \(img.fileType) · backend: \(doc.backendName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var doc: DocumentModel
    var body: some View {
        VStack(spacing: 16) {
            if let logo = AppLogo.image {
                logo.resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 108, height: 108)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            } else {
                Image(systemName: "cpu").font(.system(size: 56)).foregroundStyle(.secondary)
            }
            Text("Kernel Inspector").font(.largeTitle.bold())
            Text("Open a .kext bundle or a Mach-O binary to inspect its Info.plist, bytes, symbols, disassembly, control flow and pseudocode.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button("Open Kext or Binary…") { doc.openPanel() }
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }
}

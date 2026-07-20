import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum InstallTarget: String, CaseIterable, Identifiable {
    case libraryExtensions = "/Library/Extensions"
    case openCoreEFI = "OpenCore EFI"
    var id: String { rawValue }
}

@MainActor
final class InstallModel: ObservableObject {
    @Published var status: [StatusItem] = []
    @Published var installed: [String] = []
    @Published var selectedKext: URL?
    @Published var log: String = ""
    @Published var busy = false

    @Published var target: InstallTarget = .libraryExtensions
    @Published var ocTargets: [OCTarget] = []
    @Published var selectedOC: OCTarget?

    // AppleHDA (Tahoe) restore
    @Published var kdks: [String] = []
    @Published var selectedKDK: String?

    func refresh() {
        status = SystemStatus.items()
        installed = KextInstaller.installedKexts()
        ocTargets = EFIKextInstaller.targets()
        if selectedOC == nil || !ocTargets.contains(where: { $0.id == selectedOC?.id }) {
            selectedOC = ocTargets.first
        }
        kdks = AppleHDARestore.kdks()
        if selectedKDK == nil || !kdks.contains(selectedKDK ?? "") { selectedKDK = kdks.first }
    }

    func restoreAppleHDA() {
        guard let kdk = selectedKDK ?? kdks.first else {
            appendLog("❌ No KDK installed. Install the KDK matching your macOS build first.")
            return
        }
        let kextPath = AppleHDARestore.resolvedKextPath(kdk: kdk, chosen: selectedKext)
        busy = true
        let (_, log) = AppleHDARestore.run(kdk: kdk, kextPath: kextPath)
        busy = false
        appendLog(log)
        refresh()
    }

    func pickKext() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a .kext bundle to install"
        if panel.runModal() == .OK, let url = panel.url { selectedKext = url }
    }

    /// Entries that an EFI install would add (for the confirmation preview).
    var efiPreview: [String] {
        guard let kext = selectedKext else { return [] }
        return EFIKextInstaller.previewEntries(kextURL: kext)
    }

    func install() {
        guard let kext = selectedKext else { return }
        if target == .openCoreEFI { installToEFI(); return }
        let cmd = KextInstaller.installCommand(kextPath: kext.path)
        appendLog("$ \(cmd)")
        busy = true
        let (ok, out) = PrivilegedShell.run(cmd)
        busy = false
        appendLog(ok ? "✅ Installed \(kext.lastPathComponent)\n\(out)"
                     : "❌ \(out)")
        refresh()
    }

    func installToEFI() {
        guard let kext = selectedKext else { return }
        guard let oc = selectedOC ?? ocTargets.first else {
            appendLog("❌ No mounted OpenCore EFI. Mount it in Maintenance first.")
            return
        }
        busy = true
        let (_, log) = EFIKextInstaller.install(kextURL: kext, target: oc)
        busy = false
        appendLog(log)
        refresh()
    }

    func uninstall(_ name: String) {
        let cmd = KextInstaller.uninstallCommand(name: name)
        appendLog("$ \(cmd)")
        busy = true
        let (ok, out) = PrivilegedShell.run(cmd)
        busy = false
        appendLog(ok ? "✅ Removed \(name)\n\(out)" : "❌ \(out)")
        refresh()
    }

    /// Open a .pkg installer (e.g. HDAUniversal) in the system Installer.
    /// A .pkg does its own /L/E install + cache rebuild + kext registration —
    /// which is why audio kexts like HDAUniversal must be installed this way.
    func runPackage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if let pkg = UTType(filenameExtension: "pkg") { panel.allowedContentTypes = [pkg] }
        panel.message = "Select an installer package (.pkg) — e.g. HDAUniversal.pkg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        NSWorkspace.shared.open(url)   // launches Installer.app
        appendLog("""
        ▶︎ Opened \(url.lastPathComponent) in Installer.
        Finish the install there, then:
          1. System Settings → Privacy & Security → Allow the kernel extension
          2. Reboot
          3. Verify: kextstat | grep -i <kext>
        """)
    }

    func rebuildCaches() {
        let cmd = KextInstaller.rebuildCommand()
        appendLog("$ \(cmd)")
        busy = true
        let (ok, out) = PrivilegedShell.run(cmd)
        busy = false
        appendLog(ok ? "✅ Caches rebuilt\n\(out)" : "❌ \(out)")
    }

    private func appendLog(_ s: String) {
        log += (log.isEmpty ? "" : "\n") + s
    }
}

struct InstallKextsView: View {
    @StateObject private var model = InstallModel()
    @State private var confirmInstall = false
    @State private var confirmRestore = false
    @State private var pendingUninstall: String?

    private let cols = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                dashboard
                installer
                restoreAppleHDACard
                installedList
                if !model.log.isEmpty { logView }
            }
            .padding(20)
        }
        .onAppear { model.refresh() }
        .confirmationDialog("Restore AppleHDA into the System volume?",
                            isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Root-Patch & Rebuild", role: .destructive) { model.restoreAppleHDA() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This modifies the SEALED system volume: merges the KDK, installs AppleHDA into /S/L/E, rebuilds kernel collections, and blesses a new snapshot. Requires SIP + authenticated-root disabled (csr 0x803). The current snapshot is preserved — revert from macOS Recovery if boot fails. Takes several minutes; do not interrupt.")
        }
        .confirmationDialog(model.target == .openCoreEFI
                                ? "Install into OpenCore EFI?"
                                : "Install this kext to \(KextInstaller.targetDir)?",
                            isPresented: $confirmInstall, titleVisibility: .visible) {
            Button(model.target == .openCoreEFI ? "Install into EFI" : "Install & Rebuild Caches") {
                model.install()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if model.target == .openCoreEFI {
                Text("Copies the kext into EFI/OC/Kexts and adds its Kernel→Add entries (plus nested plugins) to config.plist. config.plist is backed up first. Reboot to load. You'll be asked for your admin password. Test on a spare EFI when possible.")
            } else {
                Text("You'll be asked for your admin password. This copies the kext, sets root:wheel ownership, and rebuilds kernel caches. On a sealed Tahoe system volume this step fails — use the OpenCore EFI target instead.")
            }
        }
        .confirmationDialog("Remove \(pendingUninstall ?? "")?",
                            isPresented: Binding(get: { pendingUninstall != nil },
                                                 set: { if !$0 { pendingUninstall = nil } }),
                            titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) {
                if let n = pendingUninstall { model.uninstall(n) }
                pendingUninstall = nil
            }
            Button("Cancel", role: .cancel) { pendingUninstall = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let logo = AppLogo.image {
                logo.resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Install Kexts").font(.title.bold())
                Text("Minimum required conditions & installation")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.refresh()
            } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
    }

    private var dashboard: some View {
        LazyVGrid(columns: cols, spacing: 12) {
            ForEach(model.status) { item in
                StatusCard(item: item)
            }
        }
    }

    private var installer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Install a Kext").font(.headline)

            Picker("Install to", selection: $model.target) {
                ForEach(InstallTarget.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if model.target == .openCoreEFI {
                if model.ocTargets.isEmpty {
                    Label("No mounted OpenCore EFI. Mount it in Maintenance first.",
                          systemImage: "externaldrive.badge.exclamationmark")
                        .font(.callout).foregroundStyle(.orange)
                } else {
                    Picker("EFI", selection: $model.selectedOC) {
                        ForEach(model.ocTargets) { t in Text(t.label).tag(Optional(t)) }
                    }
                    .labelsHidden()
                }
            }

            HStack {
                Image(systemName: "shippingbox")
                    .foregroundStyle(model.selectedKext == nil ? Color.secondary : Color.blue)
                Text(model.selectedKext?.lastPathComponent ?? "No kext selected")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(model.selectedKext == nil ? Color.secondary : Color.primary)
                Spacer()
                Button("Choose…") { model.pickKext() }
                Button {
                    confirmInstall = true
                } label: { Label("Install", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedKext == nil || model.busy ||
                              (model.target == .openCoreEFI && model.ocTargets.isEmpty))
            }

            if model.target == .openCoreEFI, !model.efiPreview.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Will add \(model.efiPreview.count) Kernel→Add entr\(model.efiPreview.count == 1 ? "y" : "ies"):")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.efiPreview, id: \.self) { p in
                        Text("• \(p)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    model.rebuildCaches()
                } label: { Label("Rebuild Caches", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(model.busy)
                Button {
                    model.runPackage()
                } label: { Label("Install Package (.pkg)…", systemImage: "shippingbox.and.arrow.backward") }
                    .help("Run a .pkg installer such as HDAUniversal — installs to /Library/Extensions and rebuilds caches")
                if model.busy { ProgressView().controlSize(.small) }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.08)))
    }

    private var restoreAppleHDACard: some View {
        let prereqs = AppleHDARestore.prereqs(kdk: model.selectedKDK, kext: model.selectedKext)
        let ready = prereqs.allSatisfy { $0.ok }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Restore AppleHDA (Tahoe / KDK)", systemImage: "speaker.wave.2.bubble")
                    .font(.headline)
                Spacer()
                Text("macOS 26 method").font(.caption).foregroundStyle(.secondary)
            }
            Text("Apple removed AppleHDA in Tahoe. It can't be OpenCore-injected — it must go into /System/Library/Extensions via a KDK root patch. This does that (sealed-volume, snapshot-based, revertible from Recovery).")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(prereqs) { p in
                HStack(spacing: 6) {
                    Image(systemName: p.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(p.ok ? .green : .orange)
                    Text(p.title).font(.callout)
                    Text("· \(p.detail)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            HStack {
                Text("KDK").font(.callout)
                if model.kdks.isEmpty {
                    Text("none installed").foregroundStyle(.orange).font(.callout)
                } else {
                    Picker("KDK", selection: $model.selectedKDK) {
                        ForEach(model.kdks, id: \.self) { Text($0).tag(Optional($0)) }
                    }.labelsHidden().frame(maxWidth: 340)
                }
                Spacer()
                Text(model.selectedKext == nil ? "AppleHDA: from KDK" : "AppleHDA: \(model.selectedKext!.lastPathComponent)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button(role: .destructive) { confirmRestore = true } label: {
                    Label("Restore AppleHDA", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ready || model.busy)
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text("⚠︎ Modifies the sealed system volume and re-blesses the boot snapshot. Have a backup; you can revert in macOS Recovery. Reboot after it finishes.")
                .font(.caption).foregroundStyle(.orange)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.25)))
    }

    private var installedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Installed in \(KextInstaller.targetDir) (\(model.installed.count))").font(.headline)
            if model.installed.isEmpty {
                Text("No third-party kexts found.").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(model.installed, id: \.self) { name in
                    HStack {
                        Image(systemName: "puzzlepiece.extension").foregroundStyle(.blue)
                        Text(name).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            pendingUninstall = name
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).disabled(model.busy)
                    }
                    .padding(.vertical, 3)
                    Divider()
                }
            }
        }
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Log").font(.headline)
                Spacer()
                Button("Clear") { model.log = "" }.buttonStyle(.borderless)
            }
            ScrollView {
                Text(model.log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 150)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.05)))
        }
    }
}

struct StatusCard: View {
    let item: StatusItem
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.title2).foregroundStyle(.blue).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline)
                HStack(spacing: 6) {
                    Image(systemName: item.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(item.ok ? .green : .orange)
                    Text(item.value).foregroundStyle(item.ok ? .green : .orange).bold()
                }
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.08)))
    }
}

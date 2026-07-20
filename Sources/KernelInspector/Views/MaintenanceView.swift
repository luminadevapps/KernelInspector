import SwiftUI
import AppKit

@MainActor
final class MaintenanceModel: ObservableObject {
    @Published var disks: [PhysicalDisk] = []
    @Published var kdks: [String] = []
    @Published var snapshots: [String] = []
    @Published var log: String = ""
    @Published var busy = false

    func refresh() {
        disks = Maintenance.physicalDisks()
        kdks = Maintenance.installedKDKs()
        snapshots = Maintenance.snapshots()
    }

    private func runPrivileged(_ cmd: String, note: String) {
        appendLog("$ \(cmd)")
        busy = true
        let (ok, out) = PrivilegedShell.run(cmd)
        busy = false
        appendLog(ok ? "✅ \(note)\n\(out)" : "❌ \(out)")
        refresh()
    }

    func mountEFI(_ part: DiskPartition) {
        runPrivileged(Maintenance.mountCommand(part.id), note: "Mounted \(part.id)")
    }
    func unmountEFI(_ part: DiskPartition) {
        runPrivileged(Maintenance.unmountCommand(part.id), note: "Unmounted \(part.id)")
    }
    func uninstallKDK(_ name: String) {
        runPrivileged(Maintenance.uninstallKDKCommand(name), note: "Removed \(name)")
    }
    func deleteSnapshot(_ name: String) {
        runPrivileged(Maintenance.deleteSnapshotCommand(name), note: "Deleted snapshot")
    }

    private func appendLog(_ s: String) { log += (log.isEmpty ? "" : "\n") + s }
}

struct MaintenanceView: View {
    @StateObject private var model = MaintenanceModel()
    @State private var confirmKDK: String?
    @State private var confirmSnap: String?
    @State private var configTarget: ConfigTarget?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                efiSection
                kdkSection
                snapshotSection
                if !model.log.isEmpty { logView }
            }
            .padding(20)
        }
        .onAppear { model.refresh() }
        .confirmationDialog("Uninstall \(confirmKDK ?? "")?",
            isPresented: Binding(get: { confirmKDK != nil }, set: { if !$0 { confirmKDK = nil } }),
            titleVisibility: .visible) {
            Button("Uninstall KDK", role: .destructive) {
                if let k = confirmKDK { model.uninstallKDK(k) }; confirmKDK = nil
            }
            Button("Cancel", role: .cancel) { confirmKDK = nil }
        } message: { Text("Removes the Kernel Debug Kit from \(Maintenance.kdkDir). Requires admin.") }
        .confirmationDialog("Delete this snapshot?",
            isPresented: Binding(get: { confirmSnap != nil }, set: { if !$0 { confirmSnap = nil } }),
            titleVisibility: .visible) {
            Button("Delete Snapshot", role: .destructive) {
                if let s = confirmSnap { model.deleteSnapshot(s) }; confirmSnap = nil
            }
            Button("Cancel", role: .cancel) { confirmSnap = nil }
        } message: { Text("Deletes an APFS snapshot of / to reclaim space. This cannot be undone.") }
        .sheet(item: $configTarget) { target in
            ConfigPlistView(path: target.path)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let logo = AppLogo.image {
                logo.resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("System Maintenance").font(.title.bold())
                Text("EFI partition · Kernel Debug Kits · APFS snapshots").foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            if model.busy { ProgressView().controlSize(.small) }
        }
    }

    // MARK: EFI / disks (ESP Mounter style)

    private var efiSection: some View {
        card {
            sectionTitle("EFI Partition Mounter", systemImage: "internaldrive")
            if model.disks.isEmpty {
                Text("No disks found. Click Refresh.").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(model.disks) { disk in
                    DiskRow(disk: disk, busy: model.busy,
                            onMount: { if let e = disk.efi { model.mountEFI(e) } },
                            onUnmount: { if let e = disk.efi { model.unmountEFI(e) } },
                            onReveal: { if let mp = disk.efi?.mountPoint { Maintenance.reveal(mp) } },
                            onConfig: {
                                if let p = Maintenance.configPlistPath(mountPoint: disk.efi?.mountPoint) {
                                    configTarget = ConfigTarget(path: p)
                                }
                            })
                    Divider()
                }
            }
        }
    }

    // MARK: KDKs

    private var kdkSection: some View {
        card {
            HStack {
                sectionTitle("Kernel Debug Kits", systemImage: "ladybug")
                Spacer()
                Button { Maintenance.openKDKDownloads() } label: {
                    Label("Download KDKs…", systemImage: "arrow.down.circle")
                }
            }
            if model.kdks.isEmpty {
                Text("No KDKs installed in \(Maintenance.kdkDir).").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(model.kdks, id: \.self) { name in
                    HStack {
                        Image(systemName: "shippingbox").foregroundStyle(.blue)
                        Text(name).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) { confirmKDK = name } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).disabled(model.busy)
                    }
                    .padding(.vertical, 3)
                    Divider()
                }
            }
        }
    }

    // MARK: Snapshots

    private var snapshotSection: some View {
        card {
            sectionTitle("APFS Snapshots (/)", systemImage: "camera.on.rectangle")
            if model.snapshots.isEmpty {
                Text("No local snapshots.").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(model.snapshots, id: \.self) { s in
                    HStack {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange)
                        Text(s).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) { confirmSnap = s } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).disabled(model.busy)
                    }
                    .padding(.vertical, 3)
                    Divider()
                }
                Text("To restore a snapshot, boot into macOS Recovery — restoring a live system is intentionally not offered here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var logView: some View {
        card {
            HStack {
                sectionTitle("Log", systemImage: "text.alignleft")
                Spacer()
                Button("Clear") { model.log = "" }.buttonStyle(.borderless)
            }
            ScrollView {
                Text(model.log).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 140)
        }
    }

    // MARK: helpers

    private func sectionTitle(_ t: String, systemImage: String) -> some View {
        Label(t, systemImage: systemImage).font(.headline)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.08)))
    }
}

/// One physical-disk row, modelled after ESP Mounter.
struct ConfigTarget: Identifiable {
    let id = UUID()
    let path: String
}

struct DiskRow: View {
    let disk: PhysicalDisk
    let busy: Bool
    let onMount: () -> Void
    let onUnmount: () -> Void
    let onReveal: () -> Void
    let onConfig: () -> Void

    private var efiMounted: Bool { disk.efi?.isMounted ?? false }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: disk.isInternal ? "internaldrive" : "externaldrive")
                .font(.title2)
                .foregroundStyle(disk.efi != nil ? Color.blue : Color.secondary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(disk.model).font(.headline)
                Text(disk.labels).font(.callout)
                HStack(spacing: 6) {
                    Text(disk.size)
                    Text("·"); Text(disk.isInternal ? "Internal" : "External")
                    if disk.osType != "Unknown" {
                        Text("·"); Text(disk.osType).foregroundStyle(disk.osType == "macOS" ? Color.blue : Color.secondary)
                    }
                    if disk.hasOpenCore {
                        Text("OC").font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.green).clipShape(Capsule())
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()

            if disk.efi != nil {
                if efiMounted {
                    if disk.hasOpenCore {
                        Button { onConfig() } label: { Label("config.plist", systemImage: "gearshape.2") }
                            .help("View OpenCore config.plist")
                    }
                    Button { onReveal() } label: { Image(systemName: "folder") }
                        .help("Reveal EFI in Finder")
                    Button("Unmount") { onUnmount() }.disabled(busy)
                } else {
                    Button { onMount() } label: { Label("Mount", systemImage: "arrow.down.circle") }
                        .buttonStyle(.borderedProminent).disabled(busy)
                }
            } else {
                Text("No EFI").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }
}

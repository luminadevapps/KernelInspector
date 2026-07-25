import SwiftUI
import AppKit

@MainActor
final class USBPortsModel: ObservableObject {
    @Published var controllers: [USBController] = []
    @Published var model: String = "iMacPro1,1"
    @Published var log: String = ""
    @Published var didLoad = false

    func refresh() {
        controllers = USBPortReader.read()
        model = USBPortReader.model()
        didLoad = true
    }

    func setEnabled(_ ctrl: Int, _ port: Int, _ on: Bool) {
        guard controllers.indices.contains(ctrl), controllers[ctrl].ports.indices.contains(port) else { return }
        controllers[ctrl].ports[port].enabled = on
    }

    func setType(_ ctrl: Int, _ port: Int, _ type: Int) {
        guard controllers.indices.contains(ctrl), controllers[ctrl].ports.indices.contains(port) else { return }
        controllers[ctrl].ports[port].type = type
    }

    /// Keep the first 15 enabled ports on a controller, disable the rest.
    func trimTo15(_ ctrl: Int) {
        guard controllers.indices.contains(ctrl) else { return }
        var kept = 0
        for pi in controllers[ctrl].ports.indices where controllers[ctrl].ports[pi].enabled {
            kept += 1
            if kept > 15 { controllers[ctrl].ports[pi].enabled = false }
        }
    }

    func exportKext() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose where to save USBPorts.kext"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            let url = try USBPortMapExporter.export(controllers: controllers, model: model, to: dir)
            log = "✅ Exported \(url.lastPathComponent) to \(dir.path)\nInstall it via Install Kexts → OpenCore EFI, then (optionally) disable the port-limit patch."
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: dir.path)
        } catch {
            log = "❌ Export failed: \(error.localizedDescription)"
        }
    }
}

struct USBPortsView: View {
    @StateObject private var model = USBPortsModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if model.didLoad && model.controllers.isEmpty { empty }
                ForEach(model.controllers.indices, id: \.self) { ci in
                    controllerCard(ci)
                }
                if !model.controllers.isEmpty { exportCard }
                if !model.log.isEmpty { logCard }
                guidance
            }
            .padding(20)
        }
        .onAppear { if !model.didLoad { model.refresh() } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let logo = AppLogo.image {
                logo.resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("USB Ports").font(.title.bold())
                Text("Live view of your USB controllers — verify the port-limit patch, or map ports to a kext")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
    }

    private var empty: some View {
        Text("No USB host controllers found via ioreg.")
            .foregroundStyle(.secondary).font(.callout)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.08)))
    }

    @ViewBuilder
    private func controllerCard(_ ci: Int) -> some View {
        let ctrl = model.controllers[ci]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "cable.connector.horizontal").foregroundStyle(.blue)
                Text(ctrl.name).font(.headline)
                Text(ctrl.ioClass).font(.caption).foregroundStyle(.secondary)
                Spacer()
                let n = ctrl.ports.count
                if ctrl.overLimit {
                    Label("\(n) ports — over the 15 cap (patch required to see all)",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Label("\(n) ports — within the 15 cap",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }

            HStack {
                Text("Enabled for map: \(ctrl.enabledCount)/15")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ctrl.enabledCount > 15 ? .red : .secondary)
                if ctrl.enabledCount > 15 {
                    Button {
                        model.trimTo15(ci)
                    } label: { Label("Auto-trim to 15", systemImage: "scissors") }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Spacer()
            }

            Divider()

            ForEach(ctrl.ports.indices, id: \.self) { pi in
                let port = model.controllers[ci].ports[pi]
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { model.controllers[ci].ports[pi].enabled },
                        set: { model.setEnabled(ci, pi, $0) })).labelsHidden()
                    Text(port.name).font(.system(.body, design: .monospaced)).frame(width: 70, alignment: .leading)
                    Text(port.kind).font(.caption).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                    Text("port \(port.portNumber)").font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { model.controllers[ci].ports[pi].type },
                        set: { model.setType(ci, pi, $0) })) {
                        ForEach(USBConnectorType.options.indices, id: \.self) { oi in
                            Text(USBConnectorType.options[oi].1).tag(USBConnectorType.options[oi].0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.08)))
    }

    private var overLimit: [USBController] { model.controllers.filter { $0.enabledCount > 15 } }
    private var nothingEnabled: Bool { model.controllers.allSatisfy { $0.enabledCount == 0 } }
    private var exportBlocked: Bool { nothingEnabled || !overLimit.isEmpty }

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Export USB Map", systemImage: "square.and.arrow.down.on.square").font(.headline)

            // Why the button is disabled — spelled out.
            if exportBlocked {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(overLimit) { c in
                        Label("\(c.name): \(c.enabledCount) enabled — over the 15 cap. Uncheck \(c.enabledCount - 15) more port\(c.enabledCount - 15 == 1 ? "" : "s") on \(c.name).",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if nothingEnabled {
                        Label("Enable at least one port to export.", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Text("SMBIOS model").font(.callout).foregroundStyle(.secondary)
                TextField("model", text: $model.model).frame(width: 180)
                Spacer()
                Button {
                    model.exportKext()
                } label: { Label("Export USBPorts.kext…", systemImage: "arrow.down.doc") }
                    .buttonStyle(.borderedProminent)
                    .disabled(exportBlocked)
            }
            Text("Exports a codeless USBPorts.kext for the enabled ports. Install it via Install Kexts → OpenCore EFI. Each controller must have ≤15 enabled ports. Verify against USBToolBox before removing the port-limit patch. (If you're keeping the port-limit patch to run all 30 ports, you don't need to export a map at all.)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.2)))
    }

    private var logCard: some View {
        Text(model.log)
            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.05)))
    }

    private var guidance: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes").font(.headline)
            Text("""
            Each HSxx (USB2) and SSxx (USB3) is a separate port; a physical USB3 port is one HS + one SS, so it uses two of the 15 slots. macOS caps each controller at 15 — if a controller shows more, the port-limit patch is what lets you see them all.

            To drop the patch: enable only the ≤15 ports you use per controller, set each type, export, install the kext, reboot, then disable the patch. To keep all ports, just leave the patch on and ignore the export.

            The exported kext matches your controller by name + SMBIOS model. It's a starting point — confirm your physical-port mapping with USBToolBox, which detects which HS/SS pair each physical port is.
            """)
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.05)))
    }
}

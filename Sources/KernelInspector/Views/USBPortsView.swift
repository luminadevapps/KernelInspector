import SwiftUI
import AppKit

/// An explicitly-typed list of indices `0..<count`.
///
/// Index iteration inside a `ForEach` is surprisingly fragile here. Swift 6.2
/// added `Collection.indices(where:)`, so a bare `.indices` can resolve to that
/// *unapplied method* instead of the property, and `Array(0..<n)` can itself
/// mis-resolve to an internal bridging initialiser. Returning an annotated
/// `[Int]` removes every inference step, so the call sites cannot drift.
private func indexList(_ count: Int) -> [Int] {
    (0..<count).map { $0 }
}

@MainActor
final class USBPortsModel: ObservableObject {
    @Published var controllers: [USBController] = []
    @Published var model: String = "iMacPro1,1"
    @Published var log: String = ""
    @Published var didLoad = false
    /// True when the current port list came from an imported map file rather
    /// than a live ioreg read. In this mode the list is the full mapped set,
    /// not what the running system is currently enumerating.
    @Published var imported = false
    /// Ports allowed per controller in the exported map (15 / 20 / 25 / 30).
    /// Anything above 15 requires the XHCI port-limit patch to enumerate.
    @Published var portLimit: Int = USBPortLimit.native { didSet { revalidate() } }

    /// Audit results, recomputed only when the map actually changes.
    /// This must NOT be a computed property on the view: auditing walks the
    /// controllers and previously re-read ioreg, and anything evaluated during
    /// a view body pass runs on every render.
    @Published private(set) var issues: [USBMapIssue] = []

    /// The machine as it was at the last refresh, used for comparison so the
    /// audit never has to shell out to ioreg itself.
    private var liveSnapshot: [USBController] = []

    func refresh() {
        controllers = USBPortReader.read()
        liveSnapshot = controllers
        model = USBPortReader.model()
        didLoad = true
        imported = false
        revalidate()
    }

    /// Load the full port set from an existing map kext (USBMap.kext /
    /// USBPorts.kext). This surfaces ports the live system is hiding — at most
    /// 15 enumerate without the port-limit patch — so a larger map can be built
    /// without removing the installed map and rebooting first. The imported set
    /// becomes the audit's reference, since there is no live hardware to compare
    /// an offline import against.
    func importMap() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a USB map kext (USBMap.kext / USBPorts.kext) or its Info.plist"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try USBPortMapImporter.importKext(at: url)
            controllers = result.controllers
            // Importing is a "give me everything to work with" action: enable
            // every port so the imported set is immediately a complete map ready
            // to export. The user disables what they don't want, rather than
            // hunting for the ones the source map happened to leave off.
            for ci in controllers.indices {
                for pi in controllers[ci].ports.indices { controllers[ci].ports[pi].enabled = true }
            }
            liveSnapshot = controllers
            model = result.model
            didLoad = true
            imported = true
            // Raise the target so a full import is not immediately "over limit".
            let maxPorts = controllers.map { $0.ports.count }.max() ?? USBPortLimit.native
            portLimit = USBPortLimit.options.first { $0 >= maxPorts } ?? USBPortLimit.options.last!
            let total = controllers.reduce(0) { $0 + $1.ports.count }
            log = "✅ Imported \(total) ports from \(url.lastPathComponent) and enabled them all. Export now for the full map, or switch off any you don't want. Refresh returns to the live system."
            revalidate()
        } catch {
            log = "❌ Import failed: \(error.localizedDescription)"
        }
    }

    /// Enable or disable every port on a controller at once.
    func setAllEnabled(_ ctrl: Int, _ on: Bool) {
        guard controllers.indices.contains(ctrl) else { return }
        for pi in controllers[ctrl].ports.indices { controllers[ctrl].ports[pi].enabled = on }
        revalidate()
    }

    /// Re-run the audit. Cheap: pure computation over in-memory state.
    func revalidate() {
        issues = USBMapAuditor.audit(controllers: controllers,
                                     limit: portLimit,
                                     live: liveSnapshot)
    }

    func setEnabled(_ ctrl: Int, _ port: Int, _ on: Bool) {
        guard controllers.indices.contains(ctrl), controllers[ctrl].ports.indices.contains(port) else { return }
        controllers[ctrl].ports[port].enabled = on
        revalidate()
    }

    func setType(_ ctrl: Int, _ port: Int, _ type: Int) {
        guard controllers.indices.contains(ctrl), controllers[ctrl].ports.indices.contains(port) else { return }
        controllers[ctrl].ports[port].type = type
        revalidate()
    }

    /// Keep the first `limit` enabled ports on a controller, disable the rest.
    func trim(_ ctrl: Int, to limit: Int) {
        guard controllers.indices.contains(ctrl) else { return }
        var kept = 0
        for pi in controllers[ctrl].ports.indices where controllers[ctrl].ports[pi].enabled {
            kept += 1
            if kept > limit { controllers[ctrl].ports[pi].enabled = false }
        }
        revalidate()
    }

    /// Re-enable every port on a controller, up to the current target.
    func fill(_ ctrl: Int, to limit: Int) {
        guard controllers.indices.contains(ctrl) else { return }
        var kept = 0
        for pi in controllers[ctrl].ports.indices {
            if kept < limit {
                controllers[ctrl].ports[pi].enabled = true
                kept += 1
            } else {
                controllers[ctrl].ports[pi].enabled = false
            }
        }
        revalidate()
    }

    func exportKext() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose where to save USBPorts.kext"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            let url = try USBPortMapExporter.export(controllers: controllers, model: model,
                                                    to: dir, portCount: portLimit)
            let tail = USBPortLimit.needsPatch(portLimit)
                ? "Install it via Install Kexts → OpenCore EFI. This map targets \(portLimit) ports per controller, so KEEP the XHCI port-limit patch enabled — macOS only enumerates \(USBPortLimit.native) without it."
                : "Install it via Install Kexts → OpenCore EFI, then (optionally) disable the port-limit patch."
            log = "✅ Exported \(url.lastPathComponent) to \(dir.path)\n\(tail)"
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
                ForEach(indexList(model.controllers.count), id: \.self) { ci in
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
                Text(model.imported
                     ? "Imported map — showing all mapped ports (offline). Refresh returns to the live system."
                     : "Live view of your USB controllers — verify the port-limit patch, or map ports to a kext")
                    .foregroundStyle(model.imported ? Color.blue : Color.secondary)
            }
            Spacer()
            Button { model.importMap() } label: { Label("Import from kext…", systemImage: "square.and.arrow.down") }
                .help("Load every port from an existing USBMap.kext / USBPorts.kext, including disabled ones, so you can build a larger map without a reboot.")
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
                if ctrl.exceedsNativeCap {
                    Label("\(n) ports — over the \(USBPortLimit.native) cap (patch required to see all)",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else if n == USBPortLimit.native {
                    // Exactly 15 is the classic signature of the enumeration cap:
                    // the controller almost certainly has more ports that macOS
                    // is not reporting without the port-limit patch.
                    Label("\(n) ports shown — macOS may be hiding more (15-port cap)",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Label("\(n) ports — within the \(USBPortLimit.native) cap",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }

            HStack {
                // "enabled / target · available". The target is a cap, not a
                // quota — you never have to fill it. The available count is the
                // real ceiling: you cannot enable more ports than the machine is
                // currently showing, whatever the target is set to.
                Text("Enabled \(ctrl.enabledCount) / target \(model.portLimit) · \(ctrl.ports.count) available")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ctrl.isOver(model.portLimit) ? Color.red : Color.secondary)
                if ctrl.isOver(model.portLimit) {
                    Button {
                        model.trim(ci, to: model.portLimit)
                    } label: { Label("Auto-trim to \(model.portLimit)", systemImage: "scissors") }
                        .buttonStyle(.bordered).controlSize(.small)
                } else if ctrl.enabledCount < min(ctrl.ports.count, model.portLimit) {
                    Button {
                        model.fill(ci, to: model.portLimit)
                    } label: { Label("Enable up to \(model.portLimit)", systemImage: "checkmark.circle") }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Button { model.setAllEnabled(ci, true) } label: { Text("All") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Enable every port on this controller.")
                Button { model.setAllEnabled(ci, false) } label: { Text("None") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Disable every port on this controller.")
                Spacer()
            }

            if ctrl.looksAlreadyMapped {
                mappedNote(ctrl)
            } else if model.portLimit > ctrl.ports.count {
                hiddenPortsNote(ctrl)
            }

            Divider()

            ForEach(indexList(ctrl.ports.count), id: \.self) { pi in
                portRow(ci, pi)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.08)))
    }

    /// One port row. Split out of the ForEach body deliberately: inline, the
    /// combination of two Bindings, interpolated ternaries, conditionals and a
    /// nested Picker overwhelmed the type checker, which then mis-resolved the
    /// enclosing ForEach to its Binding-based overload. Small functions with
    /// explicit signatures keep each expression cheap to check.
    @ViewBuilder
    private func portRow(_ ci: Int, _ pi: Int) -> some View {
        let port = model.controllers[ci].ports[pi]
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { model.controllers[ci].ports[pi].enabled },
                set: { model.setEnabled(ci, pi, $0) })).labelsHidden()
            Text(port.name)
                .font(.system(.body, design: .monospaced))
                .frame(width: 70, alignment: .leading)
            Text(port.kind)
                .font(.caption).foregroundStyle(Color.secondary)
                .frame(width: 120, alignment: .leading)
            addressLabel(port)
            occupancyBadge(port)
            if port.typeIsGuess {
                Image(systemName: "questionmark.circle")
                    .font(.caption).foregroundStyle(Color.orange)
                    .help("No firmware _UPC — this connector type is a guess.")
            }
            Spacer()
            typePicker(ci, pi)
        }
        .padding(.vertical, 2)
    }

    /// Shown when a controller's port addresses have gaps — the signature of a
    /// USB map kext that is already installed and pruning the list. This is the
    /// real reason the port-limit patch appears to do nothing: the patch cannot
    /// override an injected map, so the map has to be removed first.
    @ViewBuilder
    private func mappedNote(_ ctrl: USBController) -> some View {
        Label("\(ctrl.name)'s port numbers have gaps (highest is port \(ctrl.portAddresses.last ?? 0) but only \(ctrl.ports.count) are shown), so a USB map kext is already injecting this exact list. The port-limit patch cannot override an installed map. To see all raw ports: remove the installed map (USBMap.kext / USBPorts.kext) from config.plist and EFI/OC/Kexts, keep the port-limit patch enabled, reboot, then Refresh.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
    }

    /// Explains why a controller can show fewer ports than the chosen target.
    /// The list is a live ioreg read: macOS enumerates at most 15 ports per
    /// controller without the port-limit patch, so the rest are simply not
    /// visible yet. The app will not fabricate the missing ports — inventing
    /// port entries is what maps the wrong hardware and kills input devices.
    @ViewBuilder
    private func hiddenPortsNote(_ ctrl: USBController) -> some View {
        Label("You picked \(model.portLimit) ports, but macOS is reporting only \(ctrl.ports.count) on \(ctrl.name) right now. It enumerates at most \(USBPortLimit.native) per controller without the XHCI port-limit patch. To reveal the rest: apply the patch in Port-Limit Patch, remove any restrictive USB map already installed, reboot, then Refresh. The export can only include ports macOS is currently showing.",
              systemImage: "info.circle.fill")
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
    }

    @ViewBuilder
    private func addressLabel(_ port: USBPort) -> some View {
        let text = port.hasRealPortNumber ? "port \(port.portNumber)" : "no address"
        let tint: Color = port.hasRealPortNumber ? .secondary : .red
        Text(text)
            .font(.caption).foregroundStyle(tint)
            .frame(width: 78, alignment: .leading)
    }

    /// What is plugged in right now — so the port holding your keyboard is
    /// obvious before you switch it off.
    @ViewBuilder
    private func occupancyBadge(_ port: USBPort) -> some View {
        if port.hasInputDevice {
            Label(port.attachedDevice ?? "input device", systemImage: "keyboard.fill")
                .font(.caption).foregroundStyle(Color.red).lineLimit(1)
        } else if let dev = port.attachedDevice {
            Label(dev, systemImage: "cable.connector")
                .font(.caption).foregroundStyle(Color.blue).lineLimit(1)
        }
    }

    @ViewBuilder
    private func typePicker(_ ci: Int, _ pi: Int) -> some View {
        Picker("", selection: Binding(
            get: { model.controllers[ci].ports[pi].type },
            set: { model.setType(ci, pi, $0) })) {
            ForEach(indexList(USBConnectorType.options.count), id: \.self) { oi in
                Text(USBConnectorType.options[oi].1).tag(USBConnectorType.options[oi].0)
            }
        }
        .labelsHidden()
        .frame(width: 190)
    }

    /// Total ports that will actually appear as entries in the exported map.
    private var totalEnabled: Int { model.controllers.reduce(0) { $0 + $1.enabledCount } }

    private var overLimit: [USBController] { model.controllers.filter { $0.isOver(model.portLimit) } }
    private var nothingEnabled: Bool { model.controllers.allSatisfy { $0.enabledCount == 0 } }

    // Read the model's stored audit — never recompute it here. Anything in a
    // view body runs on every render pass.
    private var blockers: [USBMapIssue] { model.issues.filter { $0.isBlocking } }
    private var warnings: [USBMapIssue] { model.issues.filter { !$0.isBlocking } }
    private var exportBlocked: Bool { nothingEnabled || !blockers.isEmpty }

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Export USB Map", systemImage: "square.and.arrow.down.on.square").font(.headline)

            // Ports allowed per controller in the exported map. This value is
            // written as the kext's port-count; the port list above always shows
            // the real hardware ioreg detected, so changing this does not add
            // rows — it sets the count declared in the exported map.
            HStack(spacing: 8) {
                Text("Ports per controller").font(.callout).foregroundStyle(.secondary)
                Picker("", selection: $model.portLimit) {
                    ForEach(USBPortLimit.options, id: \.self) { n in
                        Text(USBPortLimit.label(n)).tag(n)
                    }
                }
                .labelsHidden()
                .frame(width: 230)
                Text("→ exported port-count").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }

            if USBPortLimit.needsPatch(model.portLimit) {
                Label("\(model.portLimit) ports needs the XHCI port-limit patch to stay enabled — macOS only enumerates \(USBPortLimit.native) on its own. Derive one in the Port-Limit Patch pane and keep it in config.plist.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Everything wrong with this map, checked against the live system.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(blockers) { i in
                    Label(i.text, systemImage: "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(warnings) { i in
                    Label(i.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if nothingEnabled {
                    Label("Enable at least one port to export.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if blockers.isEmpty && !nothingEnabled {
                    Label("Checked against the live system — no blocking problems found.",
                          systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(.green)
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
            // Make the port-count vs port-entries distinction explicit: choosing
            // a bigger target raises the declared count, it never adds entries.
            Text("This map will contain \(totalEnabled) port \(totalEnabled == 1 ? "entry" : "entries") · declared port-count \(model.portLimit). The port-count is only the cap — it does not add ports. To map more, use “Import from kext…” to load the full port set, or reveal ports with the port-limit patch.")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Exports a codeless USBPorts.kext for the enabled ports. Install it via Install Kexts → OpenCore EFI. Each controller must have ≤\(model.portLimit) enabled ports. Pick 15 for a stock, patch-free setup; pick 20/25/30 to map more ports on a system that keeps the port-limit patch. Verify against USBToolBox before relying on it.")
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
            Each HSxx (USB2) and SSxx (USB3) is a separate port; a physical USB3 port is one HS + one SS, so it uses two slots. macOS caps each controller at 15 — if a controller shows more, the port-limit patch is what lets you see them all.

            Choosing a target: 15 is the only count that works unpatched — enable the 15 ports you actually use, export, install the kext, reboot, then you can drop the port-limit patch. 20, 25 and 30 build a map covering more ports, but they only enumerate while the port-limit patch stays in config.plist; the map sets connector types, it does not raise the cap.

            The exported kext matches your controller by name + SMBIOS model. It's a starting point — confirm your physical-port mapping with USBToolBox, which detects which HS/SS pair each physical port is.
            """)
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.05)))
    }
}

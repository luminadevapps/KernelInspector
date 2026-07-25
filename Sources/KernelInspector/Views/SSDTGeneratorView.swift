import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Generates OpenCore SSDTs (ported from SSDT Maintenance) and — the "use my
/// system" part — installs the compiled `.aml` files straight into a mounted
/// OpenCore EFI, registering them under `config.plist → ACPI → Add` via the
/// same privileged machinery the Install Kexts pane uses.
@MainActor
final class SSDTGenModel: ObservableObject {

    // MARK: ACPI paths
    @Published var hdefPath = "_SB.PC00.HDEF"
    @Published var igpuPath = "_SB.PC00.IGPU"
    @Published var gpuPath  = "_SB.PC00.PEG0.PEGP"
    @Published var hdauPath = "_SB.PC00.PEG0.PEGP.HDAU"
    @Published var lanPath  = "_SB.PC00.RP01.PXSX"
    @Published var wifiPath = "_SB.PC00.RP02.PXSX"
    @Published var sataPath = "_SB.PC00.SATA"
    @Published var nvmePath = "_SB.PC00.RP04.PXSX"
    @Published var tbPath   = "_SB.PC00.RP05.PXSX"
    @Published var xhciPath = "_SB.PC00.XHCI"
    @Published var lpcPath  = "_SB.PC00.LPCB"

    // MARK: Audio
    @Published var layoutID = 7
    @Published var alcLayoutID = 12
    @Published var codecName = "Realtek Audio"

    // MARK: Presets
    @Published var igpuPreset: IGPUPreset = .raptorlake
    @Published var gpuPreset: GPUPreset = .rdna2
    @Published var lanPreset: LANPreset = .aquantiaAQC107
    @Published var wifiPreset: WIFIPreset = .intel
    @Published var tbPreset: TBPreset = .titanRidge
    @Published var usbPreset: USBPreset = .ports15
    @Published var sataPreset: SATAPreset = .intelAHCI
    @Published var nvmePreset: NVMePreset = .generic

    // MARK: Maintenance (macOS support) toggles
    @Published var mAWAC = true
    @Published var mPMC  = true
    @Published var mUSBX = true
    @Published var mEC   = true
    @Published var mSBUS = true
    @Published var mPNLF = false
    @Published var mGPRW = false
    @Published var mRHUB = false
    @Published var mALS0 = false
    @Published var mBRG0 = false

    // MARK: Output / state
    @Published var outputFolder: URL?
    @Published var log = ""
    @Published var busy = false
    @Published var compiledAML: [URL] = []

    // EFI install
    @Published var ocTargets: [OCTarget] = []
    @Published var selectedOC: OCTarget?
    /// Auto-add the ACPI→Patch renames required by installed SSDTs
    /// (EC→EC0 for SSDT-EC, _GPRW→XGPW for SSDT-GPRW).
    @Published var autoAddRenames = true

    var iaslAvailable: Bool {
        ["/usr/bin/iasl", "/usr/local/bin/iasl", "/opt/homebrew/bin/iasl"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func refreshTargets() {
        ocTargets = EFIKextInstaller.targets()
        if selectedOC == nil || !ocTargets.contains(where: { $0.id == selectedOC?.id }) {
            selectedOC = ocTargets.first
        }
    }

    /// Default working directory when the user hasn't picked one: a stable
    /// folder under Application Support so generated files persist.
    private func workingFolder() -> URL {
        if let f = outputFolder { return f }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KernelInspector/GeneratedSSDTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose where to write the generated .dsl / .aml files"
        if panel.runModal() == .OK, let url = panel.url { outputFolder = url }
    }

    private func append(_ s: String) { log += (log.isEmpty ? "" : "\n") + s }

    // MARK: Build list

    private func allSSDTs() -> [(name: String, dsl: String)] {
        var list: [(name: String, dsl: String)] = [
            ("SSDT-PLUG", SSDTBuilder.cpuPlug()),
            ("SSDT-DTPG", SSDTBuilder.dtpg()),
            ("SSDT-EC-USBX", SSDTBuilder.ecUSBX()),
            ("SSDT-HDEF", SSDTBuilder.hdef(path: hdefPath, layoutID: layoutID,
                                           alcLayoutID: alcLayoutID, codecName: codecName)),
            ("SSDT-IGPU", SSDTBuilder.igpuWithPreset(path: igpuPath, preset: igpuPreset)),
            ("SSDT-GPU", SSDTBuilder.gpuWithHDAU(gpuPath: gpuPath, hdauPath: hdauPath,
                                                 preset: gpuPreset, slotName: "PCIe Slot 1")),
            ("SSDT-LAN", SSDTBuilder.lanWithPreset(path: lanPath, preset: lanPreset, slotName: "PCIe Slot 4")),
            ("SSDT-WIFI", SSDTBuilder.wifiWithPreset(path: wifiPath, preset: wifiPreset, slotName: "PCIe Slot 3")),
            ("SSDT-TB3", SSDTBuilder.tb3WithPreset(path: tbPath, preset: tbPreset, slotName: "PCIe Slot 5")),
            ("SSDT-XHCI", SSDTBuilder.xhciWithPreset(path: xhciPath, preset: usbPreset)),
            ("SSDT-SATA", SSDTBuilder.sataWithPreset(path: sataPath, preset: sataPreset)),
            ("SSDT-NVME", SSDTBuilder.nvmeWithPreset(path: nvmePath, preset: nvmePreset))
        ]

        var maint: [(name: String, dsl: String)] = []
        if mAWAC { maint.append(("SSDT-AWAC", SSDTBuilder.awac())) }
        if mPMC  { maint.append(("SSDT-PMC",  SSDTBuilder.pmc(lpcPath: lpcPath))) }
        if mUSBX { maint.append(("SSDT-USBX", SSDTBuilder.usbx())) }
        if mEC   { maint.append(("SSDT-EC",   SSDTBuilder.fakeEC(lpcPath: lpcPath))) }
        if mSBUS { maint.append(("SSDT-SBUS-MCHC", SSDTBuilder.sbusMCHC())) }
        if mPNLF { maint.append(("SSDT-PNLF", SSDTBuilder.pnlf(gfxPath: igpuPath))) }
        if mGPRW { maint.append(("SSDT-GPRW", SSDTBuilder.gprw())) }
        if mRHUB { maint.append(("SSDT-RHUB", SSDTBuilder.rhub(xhciPath: xhciPath))) }
        if mALS0 { maint.append(("SSDT-ALS0", SSDTBuilder.als0())) }
        if mBRG0 { maint.append(("SSDT-BRG0", SSDTBuilder.brg0(parentPort: tbPath))) }

        // The maintenance EC / USBX supersede the legacy combined SSDT-EC-USBX.
        let base = (mEC || mUSBX) ? list.filter { $0.name != "SSDT-EC-USBX" } : list
        return base + maint
    }

    // MARK: Generate + compile

    func generate() {
        let folder = workingFolder()
        do {
            if !FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        } catch {
            append("❌ Cannot create output folder: \(error.localizedDescription)")
            return
        }

        busy = true
        log = ""
        compiledAML = []
        append("Output: \(folder.path)")
        if !iaslAvailable {
            append("⚠︎ iasl not found (brew install acpica). .dsl will be written; .aml will be skipped.")
        }

        var aml: [URL] = []
        for item in allSSDTs() {
            let trimmed = item.dsl.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { append("▶ \(item.name)  (skipped — empty)"); continue }
            do {
                let dslURL = try SSDTFileManager.writeDSL(name: item.name, content: item.dsl, to: folder)
                if iaslAvailable {
                    let r = SSDTCompiler.compile(dslURL: dslURL)
                    append("▶ \(item.name)  \(r.success ? "✅ compiled" : "❌ failed")")
                    if !r.stdout.isEmpty { append(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    if !r.stderr.isEmpty { append("   " + r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    let amlURL = SSDTFileManager.amlURL(for: dslURL)
                    if r.success, FileManager.default.fileExists(atPath: amlURL.path) { aml.append(amlURL) }
                } else {
                    append("▶ \(item.name)  ✅ .dsl written")
                }
            } catch {
                append("▶ \(item.name)  ❌ \(error.localizedDescription)")
            }
        }

        compiledAML = aml
        busy = false
        append(aml.isEmpty
               ? "Done. \(iaslAvailable ? "No .aml produced." : "Install iasl to compile to .aml.")"
               : "✅ Generated & compiled \(aml.count) SSDT(s). Ready to install to EFI.")
    }

    // MARK: Install to EFI

    var installPreview: [String] {
        guard let oc = selectedOC ?? ocTargets.first else { return [] }
        return SSDTInstaller.previewAdditions(amlURLs: compiledAML, target: oc)
    }

    /// ACPI renames required by the compiled SSDTs (when auto-add is on).
    var activeRenames: [ACPIRename] {
        guard autoAddRenames else { return [] }
        return ACPIRename.required(forAMLNames: compiledAML.map { $0.lastPathComponent })
    }

    /// Rename comments that would actually be added (not already in config).
    var renamePreview: [String] {
        guard let oc = selectedOC ?? ocTargets.first else { return activeRenames.map { $0.comment } }
        return SSDTInstaller.previewRenameAdditions(renames: activeRenames, target: oc)
    }

    func installToEFI() {
        guard !compiledAML.isEmpty else { append("❌ Generate & compile SSDTs first."); return }
        guard let oc = selectedOC ?? ocTargets.first else {
            append("❌ No mounted OpenCore EFI. Mount it in Maintenance first."); return
        }
        busy = true
        let (_, out) = SSDTInstaller.install(amlURLs: compiledAML, renames: activeRenames, target: oc)
        busy = false
        append(out)
        refreshTargets()
    }

    func revealOutput() {
        Maintenance.reveal(workingFolder().path)
    }
}

struct SSDTGeneratorView: View {
    @StateObject private var model = SSDTGenModel()
    @State private var confirmInstall = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                environmentCard
                pathsCard
                audioGraphicsCard
                connectivityStorageCard
                maintenanceCard
                installCard
                if !model.log.isEmpty { logView }
            }
            .padding(20)
        }
        .onAppear { model.refreshTargets() }
        .confirmationDialog("Install \(model.compiledAML.count) SSDT(s) into OpenCore EFI?",
                            isPresented: $confirmInstall, titleVisibility: .visible) {
            Button("Install into EFI") { model.installToEFI() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Copies the compiled .aml files into EFI/OC/ACPI, adds any missing ones to config.plist → ACPI → Add, and (if enabled) adds the required renames to ACPI → Patch. config.plist is backed up first. You'll be asked for your admin password. Test on a spare EFI when possible, and reboot to load.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            if let logo = AppLogo.image {
                logo.resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("SSDT Generator").font(.title.bold())
                Text("OpenCore-ready SSDTs — generate, compile with iasl, install to your EFI")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var environmentCard: some View {
        HStack(spacing: 12) {
            Image(systemName: model.iaslAvailable ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(model.iaslAvailable ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.iaslAvailable ? "iasl found — tables will compile to .aml"
                                         : "iasl not found — install with: brew install acpica")
                    .font(.callout)
                Text("Checked /usr/bin, /usr/local/bin, /opt/homebrew/bin")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill((model.iaslAvailable ? Color.green : Color.orange).opacity(0.08)))
    }

    // MARK: Paths

    private var pathsCard: some View {
        card {
            sectionTitle("ACPI Paths", systemImage: "point.3.filled.connected.trianglepath.dotted")
            Text("Confirm these against your own disassembled DSDT.")
                .font(.caption).foregroundStyle(.secondary)
            pathField("HDEF", $model.hdefPath)
            pathField("IGPU", $model.igpuPath)
            pathField("GPU",  $model.gpuPath)
            pathField("HDAU", $model.hdauPath)
            pathField("LAN",  $model.lanPath)
            pathField("Wi-Fi", $model.wifiPath)
            pathField("SATA", $model.sataPath)
            pathField("NVMe", $model.nvmePath)
            pathField("Thunderbolt", $model.tbPath)
            pathField("XHCI", $model.xhciPath)
            pathField("LPC bridge", $model.lpcPath)
        }
    }

    private var audioGraphicsCard: some View {
        card {
            sectionTitle("Audio & Graphics", systemImage: "hifispeaker.and.appletv")
            Stepper("Layout ID: \(model.layoutID)", value: $model.layoutID, in: 1...99)
            Stepper("ALC Layout ID: \(model.alcLayoutID)", value: $model.alcLayoutID, in: 1...99)
            HStack {
                Text("Codec").frame(width: 90, alignment: .leading).foregroundStyle(.secondary)
                TextField("Codec Name", text: $model.codecName)
            }
            Divider().padding(.vertical, 4)
            picker("Integrated GPU", $model.igpuPreset)
            picker("Discrete GPU", $model.gpuPreset)
        }
    }

    private var connectivityStorageCard: some View {
        card {
            sectionTitle("Connectivity & Storage", systemImage: "cable.connector")
            picker("LAN", $model.lanPreset)
            picker("Wi-Fi", $model.wifiPreset)
            picker("Thunderbolt", $model.tbPreset)
            picker("USB", $model.usbPreset)
            picker("SATA", $model.sataPreset)
            picker("NVMe", $model.nvmePreset)
        }
    }

    private var maintenanceCard: some View {
        card {
            sectionTitle("Maintenance (macOS Support)", systemImage: "wrench.adjustable")
            toggle("SSDT-AWAC", $model.mAWAC, "System clock fix — required on Z690/Z790")
            toggle("SSDT-PMC", $model.mPMC, "Native NVRAM for 300-series and newer")
            toggle("SSDT-USBX", $model.mUSBX, "USB sleep/wake power properties")
            toggle("SSDT-EC", $model.mEC, "Fake Embedded Controller — may need EC→EC0 rename")
            toggle("SSDT-SBUS-MCHC", $model.mSBUS, "SMBus + Memory Controller Hub")
            toggle("SSDT-PNLF", $model.mPNLF, "Backlight control (iGPU display)")
            toggle("SSDT-GPRW", $model.mGPRW, "Instant-wake fix — REQUIRES _GPRW→XGPW rename")
            toggle("SSDT-RHUB", $model.mRHUB, "USB root-hub reset (port re-enumeration)")
            toggle("SSDT-ALS0", $model.mALS0, "Fake ambient light sensor stub")
            toggle("SSDT-BRG0", $model.mBRG0, "PCI bridge _ADR template (advanced)")
        }
    }

    // MARK: Generate + install

    private var installCard: some View {
        card {
            sectionTitle("Generate & Install", systemImage: "bolt.fill")

            HStack {
                Button {
                    model.generate()
                } label: { Label("Generate ALL SSDTs", systemImage: "bolt.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)

                Button { model.pickFolder() } label: { Label("Output Folder…", systemImage: "folder") }
                Button { model.revealOutput() } label: { Label("Reveal", systemImage: "magnifyingglass") }
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
            }

            if let f = model.outputFolder {
                Text(f.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else {
                Text("Default: Application Support / KernelInspector / GeneratedSSDTs")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 4)

            Text("Install to OpenCore EFI").font(.headline)
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

            HStack {
                Text(model.compiledAML.isEmpty
                     ? "No compiled .aml yet — Generate first."
                     : "\(model.compiledAML.count) compiled .aml ready")
                    .font(.callout)
                    .foregroundStyle(model.compiledAML.isEmpty ? .secondary : .primary)
                Spacer()
                Button {
                    confirmInstall = true
                } label: { Label("Install to EFI", systemImage: "square.and.arrow.down.on.square") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.compiledAML.isEmpty || model.busy || model.ocTargets.isEmpty)
            }

            if !model.installPreview.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Will add \(model.installPreview.count) ACPI→Add entr\(model.installPreview.count == 1 ? "y" : "ies"):")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.installPreview, id: \.self) { p in
                        Text("• \(p)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }

            Divider().padding(.vertical, 2)

            Toggle(isOn: $model.autoAddRenames) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-add required ACPI renames")
                    Text("EC→EC0 for SSDT-EC, _GPRW→XGPW for SSDT-GPRW — written to config.plist → ACPI → Patch")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if model.autoAddRenames, !model.renamePreview.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Will add \(model.renamePreview.count) ACPI→Patch rename\(model.renamePreview.count == 1 ? "" : "s"):")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.renamePreview, id: \.self) { p in
                        Text("• \(p)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if model.renamePreview.contains(where: { $0.contains("EC to EC0") }) {
                        Text("Note: EC→EC0 only takes effect if your board's EC is named “EC”; it harmlessly matches nothing otherwise.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Log").font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.log, forType: .string)
                }.buttonStyle(.borderless)
                Button("Clear") { model.log = "" }.buttonStyle(.borderless)
            }
            ScrollView {
                Text(model.log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.05)))
        }
    }

    // MARK: Building blocks

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.08)))
    }

    private func sectionTitle(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage).font(.headline)
    }

    private func pathField(_ title: String, _ binding: Binding<String>) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading).foregroundStyle(.secondary).font(.callout)
            TextField(title, text: binding).font(.system(.body, design: .monospaced))
        }
    }

    private func toggle(_ title: String, _ binding: Binding<Bool>, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Toggle(title, isOn: binding).font(.system(.body, design: .monospaced))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func picker<T>(_ title: String, _ selection: Binding<T>) -> some View
    where T: SSDTPresetDisplayable & CaseIterable & Identifiable & Hashable,
          T.AllCases: RandomAccessCollection {
        VStack(alignment: .leading, spacing: 4) {
            Picker(title, selection: selection) {
                ForEach(Array(T.allCases)) { item in
                    Text(item.name).tag(item)
                }
            }
            Text(selection.wrappedValue.description)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preset name/description bridging
//
// The preset enums each expose `name` / `description` but don't share a
// protocol. Conforming them to this tiny protocol lets the generic picker
// above display them uniformly.

protocol SSDTPresetDisplayable {
    var name: String { get }
    var description: String { get }
}
extension IGPUPreset: SSDTPresetDisplayable {}
extension GPUPreset: SSDTPresetDisplayable {}
extension LANPreset: SSDTPresetDisplayable {}
extension WIFIPreset: SSDTPresetDisplayable {}
extension TBPreset: SSDTPresetDisplayable {}
extension USBPreset: SSDTPresetDisplayable {}
extension SATAPreset: SSDTPresetDisplayable {}
extension NVMePreset: SSDTPresetDisplayable {}

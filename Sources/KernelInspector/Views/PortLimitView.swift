import SwiftUI
import AppKit

/// Derives an XHCI port-limit OpenCore patch — from a loaded binary OR from the
/// live Kernel Collection — and shows ready Find/Replace + config.plist output.
/// Also ships the verified build-25F84 patterns as a reference.
struct PortLimitView: View {
    @EnvironmentObject var doc: DocumentModel

    @State private var newLimit: Int = 64
    @State private var matches: [PortLimitMatch] = []
    @State private var didScan = false
    @State private var scanningKC = false
    @State private var note = ""
    @State private var kcLog = ""
    @State private var showReference = false
    @State private var universalMasked = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                controls
                if didScan {
                    if matches.isEmpty { emptyResult } else { results }
                }
                referenceCard
                guidance
            }
            .padding(20)
        }
        .onAppear {
            if !didScan {
                if doc.isLoaded { scan() } else { scanKC() }   // auto-scan on open
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let logo = AppLogo.image {
                logo.resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("XHCI Port-Limit Patch").font(.title.bold())
                Text("Derives Find/Replace from a loaded binary or your live Kernel Collection")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Stepper("Raise limit to: \(newLimit) (0x\(String(newLimit, radix: 16, uppercase: true)))",
                        value: $newLimit, in: 16...255)
                    .frame(maxWidth: 300)
                if doc.isLoaded {
                    Button { scan() } label: { Label("Scan Binary", systemImage: "magnifyingglass") }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button { doc.openPanel() } label: { Label("Open Kext or Binary…", systemImage: "folder") }
                        .buttonStyle(.borderedProminent)
                }
                Button { scanKC() } label: { Label("Scan Kernel Collection", systemImage: "cpu") }
                    .disabled(scanningKC)
                if scanningKC { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text("“Scan Kernel Collection” reads /System/Library/KernelCollections/BootKernelExtensions.kc on this Mac — no binary or KDK needed.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle(isOn: $universalMasked) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Universal (masked) patch")
                    Text("Matches cmp reg,0x0F itself — build-independent, works across macOS versions. Uses Base + Mask/ReplaceMask.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !doc.isLoaded {
                Label("For a binary scan, open AppleUSBXHCI or IOUSBHostFamily (⌘O). Otherwise just Scan Kernel Collection.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let id = doc.target?.bundleIdentifier {
                Text("Loaded: \(doc.target?.displayName ?? "binary")  ·  \(id)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.08)))
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(matches.count) result\(matches.count == 1 ? "" : "s")").font(.headline)
                Spacer()
                if matches.count > 1 {
                    Button {
                        let joined = matches.map { universalMasked ? $0.maskedPlistSnippet() : $0.plistSnippet() }
                            .joined(separator: "\n")
                        copy(joined)
                        note = "Copied all \(matches.count) \(universalMasked ? "masked" : "exact") config.plist patches"
                    } label: { Label("Copy Both Patches", systemImage: "doc.on.doc") }
                        .buttonStyle(.bordered)
                }
            }
            ForEach(matches) { m in matchCard(m) }
            if !kcLog.isEmpty {
                DisclosureGroup("Kernel Collection scan log") {
                    Text(kcLog).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption)
            }
        }
    }

    private func originLabel(_ o: PatchOrigin) -> String {
        switch o {
        case .binary: return "from loaded binary"
        case .kernelCollection: return "from your Kernel Collection (live build)"
        case .reference: return "verified reference · 25F84"
        }
    }

    private func matchCard(_ m: PortLimitMatch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: m.verified ? "checkmark.seal.fill" : "questionmark.diamond")
                    .foregroundStyle(m.verified ? .green : .orange)
                Text(m.functionName).font(.system(.body, design: .monospaced)).bold()
                Spacer()
                Text(originLabel(m.origin)).font(.caption)
                    .foregroundStyle(m.verified ? .green : .orange)
            }
            Text("\(m.identifier.isEmpty ? "unknown bundle id" : m.identifier)"
                 + (m.origin == .reference ? "" : "  ·  vmaddr 0x\(String(m.vmaddr, radix: 16))"))
                .font(.caption).foregroundStyle(.secondary)

            if universalMasked {
                row("Find",        m.maskedFindHex,        b64: m.maskedFindB64)
                row("Mask",        m.maskedMaskHex,        b64: m.maskedMaskB64)
                row("Replace",     m.maskedReplaceHex,     b64: m.maskedReplaceB64)
                row("ReplaceMask", m.maskedReplaceMaskHex, b64: m.maskedReplaceMaskB64)
            } else {
                row("Find",    m.findHex,    b64: m.findB64)
                row("Replace", m.replaceHex, b64: m.replaceB64)
            }

            HStack(spacing: 10) {
                Button {
                    copy(universalMasked ? m.maskedPlistSnippet() : m.plistSnippet())
                    note = "Copied \(universalMasked ? "universal masked" : "exact") config.plist patch for \(m.functionName)"
                } label: { Label("Copy config.plist Patch", systemImage: "doc.on.clipboard") }
                    .buttonStyle(.borderedProminent)

                if m.origin == .binary {
                    Button {
                        doc.patch(offset: m.fileOffset, bytes: m.replace)
                        note = "Patched \(m.replace.count) bytes at 0x\(String(m.fileOffset, radix: 16)). Use Save Patched (⌘S) to write it out."
                    } label: { Label("Patch Binary In-Place", systemImage: "bandage") }
                }
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill((m.verified ? Color.green : Color.orange).opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke((m.verified ? Color.green : Color.orange).opacity(0.25)))
    }

    private func row(_ label: String, _ hex: String, b64: String) -> some View {
        HStack {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Text(hex).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button("Copy hex") { copy(hex.replacingOccurrences(of: " ", with: "")) }
                .buttonStyle(.borderless).font(.caption)
            Button("Copy base64") { copy(b64) }
                .buttonStyle(.borderless).font(.caption)
        }
    }

    private var emptyResult: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No port-limit compare found.", systemImage: "magnifyingglass").font(.headline)
            Text("Confirm you loaded AppleUSBXHCI / IOUSBHostFamily, or use Scan Kernel Collection. If the KC scan logged “no matching symbol”, the symbols may be stripped — tell me and I'll switch to a section-scan fallback.")
                .font(.callout).foregroundStyle(.secondary)
            if !kcLog.isEmpty {
                DisclosureGroup("Scan log") {
                    Text(kcLog).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.08)))
    }

    private var referenceCard: some View {
        DisclosureGroup(isExpanded: $showReference) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Confirmed against macOS build 25F84 (Tahoe). If your build differs, use a live scan above — these may not match.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(PortLimitScanner.reference25F84(newLimit: UInt8(clamping: newLimit))) { m in
                    matchCard(m)
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Verified reference patterns (build 25F84)", systemImage: "checkmark.seal")
                .font(.headline)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
    }

    private var guidance: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How it works").font(.headline)
            Text("""
            The port limit is a single compare against 15 (0x0F). Raising it to \(newLimit) removes the 15-port cap. The surrounding bytes differ between macOS builds, so the pattern is read from real code — either the binary you load, or your live Kernel Collection — rather than hard-coded.

            Paste the copied config.plist patch into Kernel → Patch. This is a temporary step for USB mapping: once you've built a proper USBMap/USBToolBox kext, remove the port-limit patch. Scope with MinKernel/MaxKernel if you run multiple macOS versions.
            """)
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.05)))
    }

    // MARK: - Actions

    private func scan() {
        guard let img = doc.image else { note = "No binary loaded."; return }
        matches = PortLimitScanner.scan(image: img, data: doc.fileData,
                                        bundleID: doc.target?.bundleIdentifier,
                                        newLimit: UInt8(clamping: newLimit))
        kcLog = ""; didScan = true
        note = matches.isEmpty ? "Scanned — no port-limit compare found."
                               : "Scanned \(doc.target?.displayName ?? "binary") — \(matches.count) result(s)."
    }

    private func scanKC() {
        scanningKC = true; note = "Reading Kernel Collection…"
        let limit = UInt8(clamping: newLimit)
        DispatchQueue.global(qos: .userInitiated).async {
            let (m, log) = PortLimitScanner.scanKernelCollection(newLimit: limit)
            DispatchQueue.main.async {
                matches = m; kcLog = log; didScan = true; scanningKC = false
                note = m.isEmpty ? "Kernel Collection scan found nothing — see the log."
                                 : "Derived \(m.count) patch(es) from your live Kernel Collection."
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

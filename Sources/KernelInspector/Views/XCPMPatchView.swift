import SwiftUI
import AppKit

/// Shows the verified CPU/XCPM patch set for this machine and checks each
/// against the live Kernel Collection. Copy the config.plist entries or verify
/// after a macOS update.
struct XCPMPatchView: View {
    @State private var patches: [XCPMPatch] = XCPMLibrary.reference
    @State private var verifying = false
    @State private var didVerify = false
    @State private var note = ""
    @State private var log = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                controls
                ForEach(patches) { p in patchCard(p) }
                if !log.isEmpty {
                    DisclosureGroup("Verify log") {
                        Text(log).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.caption).padding(.horizontal, 4)
                }
                guidance
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let logo = AppLogo.image {
                logo.resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("XCPM / CPU Patches").font(.title.bold())
                Text("Verified CPU power-management + topology patches for this build — copy or verify")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    verify()
                } label: { Label(verifying ? "Verifying…" : "Verify against Kernel Collection", systemImage: "checkmark.shield") }
                    .buttonStyle(.borderedProminent)
                    .disabled(verifying)
                if verifying { ProgressView().controlSize(.small) }
                Button {
                    let all = patches.map { $0.plistSnippet() }.joined(separator: "\n")
                    copy(all); note = "Copied all \(patches.count) XCPM patches"
                } label: { Label("Copy All Patches", systemImage: "doc.on.doc") }
                    .buttonStyle(.bordered)
                Spacer()
            }
            Label("These are specific to i9-13900K on macOS 26.x (Darwin 25). Verify after any macOS update.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
            if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.08)))
    }

    private func patchCard(_ p: XCPMPatch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: badgeIcon(p)).foregroundStyle(badgeColor(p))
                Text(p.name).font(.headline)
                Spacer()
                if let m = p.matched {
                    Text(m ? "MATCH (\(p.hits) hit\(p.hits == 1 ? "" : "s"))" : "BROKEN — re-derive needed")
                        .font(.caption).foregroundStyle(m ? .green : .red)
                } else {
                    Text("not verified").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(p.note).font(.caption).foregroundStyle(.secondary)

            textRow("Identifier", p.identifier)
            textRow("Base", p.base.isEmpty ? "—  (raw kernel scan, no symbol anchor)" : p.base,
                    copyable: !p.base.isEmpty)
            if !p.cpus.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text("CPUs").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 78, alignment: .leading)
                    Text(p.cpus).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
            Text("Count \(p.count)  ·  Mask \(p.mask.isEmpty ? "none (exact match)" : "\(p.mask.count) bytes")  ·  kernel \(p.minKernel)–\(p.maxKernel)")
                .font(.caption2).foregroundStyle(.secondary)

            row("Find", p.findHex, b64: p.findB64)
            row("Replace", p.replaceHex, b64: p.replaceB64)

            Button {
                copy(p.plistSnippet()); note = "Copied config.plist patch: \(p.name)"
            } label: { Label("Copy config.plist Patch", systemImage: "doc.on.clipboard") }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(cardTint(p)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(cardStroke(p)))
    }

    private func badgeIcon(_ p: XCPMPatch) -> String {
        guard let m = p.matched else { return "cpu" }
        return m ? "checkmark.seal.fill" : "xmark.seal.fill"
    }
    private func badgeColor(_ p: XCPMPatch) -> Color {
        guard let m = p.matched else { return .blue }
        return m ? .green : .red
    }
    private func cardTint(_ p: XCPMPatch) -> Color {
        guard let m = p.matched else { return Color.gray.opacity(0.06) }
        return (m ? Color.green : Color.red).opacity(0.06)
    }
    private func cardStroke(_ p: XCPMPatch) -> Color {
        guard let m = p.matched else { return Color.black.opacity(0.06) }
        return (m ? Color.green : Color.red).opacity(0.25)
    }

    private func row(_ label: String, _ hex: String, b64: String) -> some View {
        HStack {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            Text(hex).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Copy hex") { copy(hex.replacingOccurrences(of: " ", with: "")) }.buttonStyle(.borderless).font(.caption)
            Button("Copy base64") { copy(b64) }.buttonStyle(.borderless).font(.caption)
        }
    }

    /// A plain text field row (Identifier / Base) mirroring the config.plist keys.
    private func textRow(_ label: String, _ value: String, copyable: Bool = true) -> some View {
        HStack {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer()
            if copyable {
                Button("Copy") { copy(value) }.buttonStyle(.borderless).font(.caption)
            }
        }
    }

    private var guidance: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes").font(.headline)
            Text("""
            XCPM active is confirmed in Terminal with: sysctl -n machdep.xcpm.mode  (1 = on).

            These patches let XCPM run on a high-core-count hybrid CPU: the ExtraMsrs entries stop it writing MSRs the CPU rejects, CfgLock raises the core-count limit, and the topology fix corrects P/E scheduling. They're paired with your MacPro7,1 SMBIOS and CpuTopologyRebuild.kext.

            Because these encode build-specific offsets, a macOS update can invalidate them. After updating, hit Verify — anything that turns BROKEN needs re-deriving (that's a manual, CPU-specific job; ping me with the details). If XCPM ever falls back to mode 0, that's the signal one of these stopped applying.

            CPU coverage: the CfgLock and topology fixes are the SAME bytes across 12th/13th/14th Gen (Alder Lake, Raptor Lake, Raptor Lake Refresh) — an i9-14900K, i7-14700K or i9-12900K uses these exact patches, so the "CPUs" line on each card lists who it applies to. The ExtraMsrs table entries are Raptor-Lake-family + build-specific. Arrow Lake / Core Ultra 200S (265K/285K) is a different, non-HT architecture: per CpuTopologyRebuild it does NOT need the topology quirk, and its MSR set differs — so don't copy the c1e1 topology patch onto it. Genuinely new silicon needs bytes derived on that machine, not reused blind.
            """)
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.05)))
    }

    // MARK: Actions

    private func verify() {
        verifying = true; note = "Reading Kernel Collection…"
        DispatchQueue.global(qos: .userInitiated).async {
            let (res, l) = XCPMLibrary.verify(XCPMLibrary.reference)
            DispatchQueue.main.async {
                patches = res; log = l; verifying = false; didVerify = true
                let broken = res.filter { $0.matched == false }.count
                note = broken == 0 ? "All \(res.count) patches match this build ✅"
                                   : "\(broken) of \(res.count) need re-deriving for this build"
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

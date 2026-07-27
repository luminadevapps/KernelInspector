import SwiftUI
import AppKit

/// All-in-one macOS kext / kernel inspector.
///
/// Open a `.kext` bundle, a Mach-O executable, or any binary and explore it
/// through panes modelled loosely on Hopper Disassembler, plus Hackintosh
/// system tools (Install Kexts, EFI mounter, maintenance).
@main
struct KernelInspectorApp: App {
    @StateObject private var document = DocumentModel()
    @StateObject private var updater = UpdateChecker()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(document)
                .environmentObject(updater)
                .frame(minWidth: 1150, minHeight: 720)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Kernel Inspector") { AboutPanel.show() }
                Button(updater.isChecking ? "Checking for Updates…" : "Check for Updates…") {
                    updater.checkNow()
                }
                .disabled(updater.isChecking)
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Open Kext or Binary…") { document.openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Save Patched Binary…") { document.saveAsPanel() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!document.isLoaded)
                Button("Close Binary (Reset)") { document.reset() }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(!document.isLoaded)
            }
        }
    }
}

/// Builds a rich standard About panel with a description, feature list and
/// technical details in the credits area.
enum AboutPanel {
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Kernel Inspector",
            .credits: credits()
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func credits() -> NSAttributedString {
        let out = NSMutableAttributedString()

        func line(_ s: String, size: CGFloat = 11, bold: Bool = false,
                  color: NSColor = .labelColor, spacingAfter: CGFloat = 3, link: String? = nil) {
            let para = NSMutableParagraphStyle()
            para.paragraphSpacing = spacingAfter
            para.alignment = .center
            let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: para
            ]
            if let link = link, let url = URL(string: link) { attrs[.link] = url }
            out.append(NSAttributedString(string: s + "\n", attributes: attrs))
        }

        line("Lumina Dev Apps", size: 13, bold: true, spacingAfter: 2)
        line("A division of Direct Parcel Distributors Inc.",
             size: 11, color: .secondaryLabelColor, spacingAfter: 2)
        line("1335 Apollo St, Oshawa, Ontario  L1K 3E6",
             size: 11, color: .secondaryLabelColor, spacingAfter: 10)

        line("luminadevapps.com", size: 11, color: .linkColor,
             spacingAfter: 3, link: "https://luminadevapps.com")
        line("support@luminadevapps.com", size: 11, color: .linkColor,
             spacingAfter: 3, link: "mailto:support@luminadevapps.com")
        line("github.com/luminadevapps", size: 11, color: .linkColor,
             spacingAfter: 8, link: "https://github.com/luminadevapps")
        line("\u{2665} Donate — support development", size: 11, bold: true, color: .linkColor,
             spacingAfter: 10, link: "https://www.paypal.com/donate/?business=H3PV9HX92AVMJ&no_recurring=0&item_name=Support+my+suite+of+open-source+apps+and+tools.+Contributions+help+sustain+development%2C+testing%2C+and+infrastructure+costs.&currency_code=CAD")

        line("© 2026 Lumina Dev Apps", size: 10, color: .tertiaryLabelColor)

        return out
    }
}

import SwiftUI

/// The update dialog: shows the new version's release notes and drives the
/// download-and-install flow. Presented as a sheet when an update is found (and
/// re-openable from the banner or the "Check for Updates…" menu item).
struct UpdateSheetView: View {
    let update: UpdateChecker.Update
    let currentVersion: String
    var onSkip: () -> Void
    var onLater: () -> Void

    @StateObject private var installer: UpdateInstaller

    init(update: UpdateChecker.Update,
         currentVersion: String,
         onSkip: @escaping () -> Void,
         onLater: @escaping () -> Void) {
        self.update = update
        self.currentVersion = currentVersion
        self.onSkip = onSkip
        self.onLater = onLater
        _installer = StateObject(wrappedValue: UpdateInstaller(update: update))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            releaseNotes
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 540, height: 470)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Kernel Inspector \(update.displayVersion) is available")
                    .font(.title3.bold())
                Text("You're currently on \(currentVersion).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: Release notes

    private var releaseNotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What's new")
                .font(.headline)
            ScrollView {
                Text(update.notes.isEmpty ? "No release notes were provided for this version."
                                          : update.notes)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Footer (state-dependent actions)

    @ViewBuilder
    private var footer: some View {
        switch installer.phase {
        case .idle:
            HStack {
                Button("Skip This Version") { onSkip() }
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Later") { onLater() }
                Button("Download & Install") { installer.start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }

        case .downloading(let progress):
            HStack(spacing: 12) {
                ProgressView(value: progress)
                    .frame(maxWidth: .infinity)
                Text("\(Int(progress * 100))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancel") { installer.cancel() }
            }

        case .preparing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Preparing update…").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { installer.cancel() }
            }

        case .readyToRelaunch:
            HStack {
                Text("Update downloaded. Kernel Inspector will quit and relaunch.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Install & Relaunch") { installer.installAndRelaunch() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Later") { onLater() }
                    Button("Open Download Page") {
                        NSWorkspace.shared.open(update.pageURL)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

import SwiftUI

/// A thin banner shown at the top of the main window when a newer release is
/// available.
///
/// - **View Update** opens the release-notes / install dialog.
/// - **Later** hides the banner until the next check.
/// - **Skip** suppresses this specific version for good.
struct UpdateBannerView: View {
    @EnvironmentObject var updater: UpdateChecker

    var body: some View {
        if let update = updater.availableUpdate {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Kernel Inspector \(update.displayVersion) is available")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("You're on \(updater.currentVersion). See what's new and update.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button("Skip") { updater.skipCurrentUpdate() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.85))
                    .help("Don't notify me about \(update.displayVersion) again")

                Button("Later") { updater.dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)

                Button("View Update") { updater.showDetails() }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(Color.accentColor)
                    .help("See release notes and install \(update.displayVersion)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.accentColor)
        }
    }
}

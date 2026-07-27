import Foundation
import AppKit

/// Checks GitHub Releases for a newer Kernel Inspector build and, when one is
/// found, exposes it so the UI can offer a one-click update.
///
/// The networking is deliberately tiny: a single request to the public
/// `releases/latest` endpoint — no auth, no third-party dependency. If anything
/// goes wrong (offline, rate-limited, malformed JSON) the checker just stays
/// quiet: a failed update check must never interrupt the app.
@MainActor
final class UpdateChecker: ObservableObject {

    /// A release that is newer than the running build.
    struct Update: Identifiable, Equatable {
        let id = UUID()
        /// Normalised numeric version, e.g. "1.1.2".
        let version: String
        /// Original release tag as shown to the user, e.g. "v1.1.2".
        let displayVersion: String
        /// Release notes / body (may be empty).
        let notes: String
        /// Where "Update" sends the user — the `.dmg` asset when present,
        /// otherwise the release web page.
        let downloadURL: URL
        /// The release's page on GitHub.
        let pageURL: URL

        static func == (lhs: Update, rhs: Update) -> Bool {
            lhs.version == rhs.version && lhs.downloadURL == rhs.downloadURL
        }
    }

    /// Set when a newer release is available; the banner observes this.
    @Published private(set) var availableUpdate: Update?
    /// True while a check is in flight (drives the menu's progress text).
    @Published private(set) var isChecking = false
    /// Set after a *user-initiated* check that found nothing newer, so the UI
    /// can show a one-shot "you're up to date" confirmation.
    @Published var lastCheckWasUpToDate = false
    /// Drives the release-notes / install sheet. Auto-set when an update is
    /// found; the banner and menu can re-open it.
    @Published var isShowingDetails = false

    // GitHub repository the releases live under.
    private let owner = "luminadevapps"
    private let repo  = "KernelInspector"

    private let session: URLSession
    private let defaults: UserDefaults
    private let skippedKey = "UpdateChecker.skippedVersion"

    init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
    }

    /// The running app's marketing version (CFBundleShortVersionString), e.g. "1.1.1".
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Triggering a check

    /// Silent check used on launch. Honours a version the user chose to skip.
    func checkInBackground() {
        Task { await check(userInitiated: false) }
    }

    /// Explicit check from the "Check for Updates…" menu item. Ignores the skip
    /// list and reports "up to date" when there is nothing newer.
    func checkNow() {
        Task { await check(userInitiated: true) }
    }

    func check(userInitiated: Bool) async {
        if isChecking { return }
        isChecking = true
        lastCheckWasUpToDate = false
        defer { isChecking = false }

        guard let latest = await fetchLatestRelease() else { return }

        guard Self.isVersion(latest.version, newerThan: currentVersion) else {
            availableUpdate = nil
            if userInitiated { lastCheckWasUpToDate = true }
            return
        }

        // A background check respects a version the user explicitly skipped;
        // an explicit check always surfaces it.
        if !userInitiated, defaults.string(forKey: skippedKey) == latest.version {
            return
        }
        availableUpdate = latest
        isShowingDetails = true          // auto-present the release-notes dialog.
    }

    // MARK: - Banner / menu actions

    /// Re-open the release-notes / install dialog for the pending update.
    func showDetails() {
        guard availableUpdate != nil else { return }
        isShowingDetails = true
    }

    /// "Click to update" — opens the download directly (kept as a fallback).
    func openUpdate() {
        guard let update = availableUpdate else { return }
        NSWorkspace.shared.open(update.downloadURL)
    }

    /// Hide the banner/dialog for now; it can reappear on the next check.
    func dismiss() {
        isShowingDetails = false
        availableUpdate = nil
    }

    /// "Don't tell me about this version again."
    func skipCurrentUpdate() {
        if let version = availableUpdate?.version {
            defaults.set(version, forKey: skippedKey)
        }
        isShowingDetails = false
        availableUpdate = nil
    }

    // MARK: - Networking

    private func fetchLatestRelease() async -> Update? {
        guard let url = URL(string:
            "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects requests without a User-Agent.
        request.setValue("KernelInspector", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return Self.parseRelease(data)
        } catch {
            return nil   // offline, cancelled, timed out — stay quiet.
        }
    }

    /// Turn GitHub's release JSON into an `Update`, preferring a `.dmg` asset's
    /// direct download URL and skipping drafts / pre-releases.
    static func parseRelease(_ data: Data) -> Update? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = obj["tag_name"] as? String,
            let pageString = obj["html_url"] as? String,
            let pageURL = URL(string: pageString)
        else { return nil }

        if (obj["draft"] as? Bool) == true { return nil }
        if (obj["prerelease"] as? Bool) == true { return nil }

        let version = normalise(tag)
        guard !version.isEmpty else { return nil }

        // Prefer a .dmg asset's browser_download_url; fall back to the page.
        var downloadURL = pageURL
        if let assets = obj["assets"] as? [[String: Any]],
           let dmg = assets.first(where: {
               (($0["name"] as? String) ?? "").lowercased().hasSuffix(".dmg")
           }),
           let assetString = dmg["browser_download_url"] as? String,
           let assetURL = URL(string: assetString) {
            downloadURL = assetURL
        }

        return Update(version: version,
                      displayVersion: tag,
                      notes: (obj["body"] as? String) ?? "",
                      downloadURL: downloadURL,
                      pageURL: pageURL)
    }

    // MARK: - Version comparison

    /// Strip a leading "v" and any pre-release/build suffix, keeping the dotted
    /// numeric core (e.g. "v1.2.0-beta" → "1.2.0").
    static func normalise(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        let core = s.prefix { $0.isNumber || $0 == "." }
        return String(core)
    }

    /// True when `candidate` is a strictly higher version than `current`, using
    /// component-wise numeric comparison so that "1.10" > "1.9".
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = components(candidate)
        let b = components(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        normalise(version).split(separator: ".").map { Int($0) ?? 0 }
    }
}

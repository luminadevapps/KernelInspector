import Foundation
import AppKit

/// Downloads a release DMG, extracts the app it contains, and swaps it in for
/// the running copy — the "Download & Install" path behind the update dialog.
///
/// This is deliberately conservative. Anything uncertain (no write access to
/// the install location, a DMG without an app, a failed shell step) surfaces as
/// a `.failed` phase so the UI can offer the manual download page instead of
/// leaving the user stuck. Nothing destructive happens until the very last
/// step, when the user presses "Install & Relaunch".
@MainActor
final class UpdateInstaller: ObservableObject {

    enum Phase: Equatable {
        case idle
        case downloading(progress: Double)   // 0...1
        case preparing                       // mounting + extracting
        case readyToRelaunch
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private let update: UpdateChecker.Update
    private var work: Task<Void, Never>?
    private var downloader: DMGDownloader?
    private var stagedAppURL: URL?

    init(update: UpdateChecker.Update) { self.update = update }

    // MARK: - Flow

    /// Begin downloading + preparing the update.
    func start() {
        guard case .idle = phase else { return }
        work = Task { await run() }
    }

    /// Cancel an in-flight download/preparation and reset.
    func cancel() {
        downloader?.cancel()
        work?.cancel()
        phase = .idle
    }

    private func run() async {
        do {
            phase = .downloading(progress: 0)

            let dl = DMGDownloader { [weak self] p in
                Task { @MainActor in
                    guard let self else { return }
                    if case .downloading = self.phase { self.phase = .downloading(progress: p) }
                }
            }
            downloader = dl
            let dmg = try await dl.download(update.downloadURL)
            try Task.checkCancellation()

            phase = .preparing
            let app = try await Task.detached(priority: .userInitiated) {
                try UpdateInstaller.extractApp(fromDMG: dmg)
            }.value
            try Task.checkCancellation()

            stagedAppURL = app
            phase = .readyToRelaunch
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Final step: replace the installed bundle and relaunch. Quits the app so a
    /// small helper script can swap the bundle while it isn't running.
    func installAndRelaunch() {
        guard case .readyToRelaunch = phase, let staged = stagedAppURL else { return }

        let installed = Bundle.main.bundleURL
        let parent = installed.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            phase = .failed(UpdateError.notWritable(parent.path).localizedDescription)
            return
        }

        do {
            try UpdateInstaller.swapAndRelaunch(newApp: staged, installedApp: installed)
            // Exit hard rather than NSApp.terminate(): the update dialog is a modal
            // sheet, and AppKit refuses (and just beeps) if asked to terminate during
            // a modal session. exit() bypasses that and guarantees we quit so the
            // detached helper can swap the bundle. Small delay lets the helper spawn.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                exit(0)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - DMG handling (runs off the main actor)

    /// Mount the DMG, copy the `.app` it contains to a staging dir, strip the
    /// quarantine flag, and unmount. Returns the staged app URL.
    nonisolated static func extractApp(fromDMG dmg: URL) throws -> URL {
        let fm = FileManager.default
        let mountPoint = fm.temporaryDirectory
            .appendingPathComponent("KI-mnt-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        try shell("/usr/bin/hdiutil",
                  ["attach", dmg.path, "-nobrowse", "-noverify", "-mountpoint", mountPoint.path])
        defer {
            _ = try? shell("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
            try? fm.removeItem(at: dmg)
        }

        let contents = try fm.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
        guard let appOnVolume = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.appNotFoundInDMG
        }

        let staging = fm.temporaryDirectory
            .appendingPathComponent("KI-stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let stagedApp = staging.appendingPathComponent(appOnVolume.lastPathComponent)

        try shell("/usr/bin/ditto", [appOnVolume.path, stagedApp.path])
        // Downloaded bundles carry a quarantine xattr; strip it so the relaunched
        // copy isn't blocked by Gatekeeper (matches the ad-hoc-signed workflow).
        _ = try? shell("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stagedApp.path])

        return stagedApp
    }

    /// Write and launch a detached helper that waits for this process to exit,
    /// replaces the installed bundle atomically, and relaunches it.
    nonisolated static func swapAndRelaunch(newApp: URL, installedApp: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let target = installedApp.path
        let source = newApp.path
        let log = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Logs/KernelInspectorUpdate.log")

        let script = """
        #!/bin/bash
        exec >> "\(log)" 2>&1
        echo "[$(date)] helper start — waiting for pid \(pid) to quit"
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/sleep 0.3
        echo "[$(date)] swapping bundle: \(target)"
        /usr/bin/ditto "\(source)" "\(target).new" || { echo "ditto failed"; exit 1; }
        /bin/rm -rf "\(target)"
        /bin/mv "\(target).new" "\(target)" || { echo "mv failed"; exit 1; }
        /usr/bin/xattr -dr com.apple.quarantine "\(target)" 2>/dev/null
        echo "[$(date)] relaunching"
        /usr/bin/open "\(target)"
        echo "[$(date)] done"
        """

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ki-update-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        // Launch fully detached (nohup + background) so the helper survives our
        // exit: the outer shell backgrounds the job and returns immediately, and
        // the job is reparented to launchd rather than dying with us.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "nohup /bin/bash \"\(scriptURL.path)\" >/dev/null 2>&1 &"]
        try p.run()
        p.waitUntilExit()   // returns at once — the real work is backgrounded.
    }

    /// Run a command, capturing output; throws with the output on non-zero exit.
    @discardableResult
    nonisolated static func shell(_ launchPath: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw UpdateError.command("\((launchPath as NSString).lastPathComponent) failed "
                                      + "(exit \(p.terminationStatus)): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return out
    }
}

// MARK: - Errors

enum UpdateError: LocalizedError {
    case appNotFoundInDMG
    case command(String)
    case notWritable(String)

    var errorDescription: String? {
        switch self {
        case .appNotFoundInDMG:
            return "The downloaded disk image didn't contain a Kernel Inspector app."
        case .command(let message):
            return message
        case .notWritable(let path):
            return "Can't write to \(path). Move Kernel Inspector into /Applications and try again, "
                 + "or use “Open Download Page” to install it manually."
        }
    }
}

// MARK: - Progress-reporting DMG downloader

/// A tiny `URLSessionDownloadDelegate` wrapper that downloads a file to a stable
/// temp path while reporting fractional progress. Isolated from the installer so
/// the delegate callbacks (which arrive off the main thread) stay self-contained.
private final class DMGDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func download(_ url: URL) async throws -> URL {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("KernelInspector", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let task = session.downloadTask(with: request)
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        task?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // `location` is removed once this method returns — move it somewhere stable.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernelInspectorUpdate-\(UUID().uuidString).dmg")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume(returning: dest)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else { return }   // success already handled above.
        if (error as NSError).code == NSURLErrorCancelled {
            continuation?.resume(throwing: CancellationError())
        } else {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }
}

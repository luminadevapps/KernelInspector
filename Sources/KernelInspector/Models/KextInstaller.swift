import Foundation

/// Runs a shell command as root via the macOS authorization prompt.
/// The user types their password into the system dialog — this app never
/// sees or stores it.
enum PrivilegedShell {
    static func run(_ command: String) -> (ok: Bool, output: String) {
        let script = "do shell script \"\(escape(command))\" with administrator privileges"
        guard let apple = NSAppleScript(source: script) else {
            return (false, "Could not construct authorization script.")
        }
        var err: NSDictionary?
        let result = apple.executeAndReturnError(&err)
        if let err = err {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "Authorization cancelled or failed."
            return (false, msg)
        }
        return (true, result.stringValue ?? "")
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Builds and runs kext install / uninstall / cache-rebuild operations.
enum KextInstaller {
    static let targetDir = "/Library/Extensions"

    static func rebuildCommand() -> String {
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/kmutil") {
            return "/usr/bin/kmutil install --update-all"
        }
        return "/usr/sbin/kextcache -i /"
    }

    /// Full command chain to install a kext bundle and rebuild caches.
    static func installCommand(kextPath: String) -> String {
        let name = (kextPath as NSString).lastPathComponent
        let dest = "\(targetDir)/\(name)"
        return [
            "/bin/cp -R '\(kextPath)' '\(targetDir)/'",
            "/usr/sbin/chown -R root:wheel '\(dest)'",
            "/bin/chmod -R 755 '\(dest)'",
            rebuildCommand()
        ].joined(separator: " && ")
    }

    static func uninstallCommand(name: String) -> String {
        "/bin/rm -rf '\(targetDir)/\(name)' && \(rebuildCommand())"
    }

    static func installedKexts() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: targetDir))?
            .filter { $0.hasSuffix(".kext") }
            .sorted() ?? []
    }
}

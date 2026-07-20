import Foundation

struct StatusItem: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let detail: String
    let ok: Bool
    let systemImage: String
}

/// Reads read-only system facts relevant to installing kexts.
enum SystemStatus {

    /// Run a non-privileged tool and capture its combined output.
    static func run(_ launch: String, _ args: [String]) -> String {
        guard FileManager.default.isExecutableFile(atPath: launch) else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sipDisabled() -> (disabled: Bool, raw: String) {
        let out = run("/usr/bin/csrutil", ["status"]).lowercased()
        // "System Integrity Protection status: disabled." (good for kext installs)
        let disabled = out.contains("disabled")
        return (disabled, out.isEmpty ? "unknown" : out)
    }

    static func macOSVersion() -> (product: String, build: String) {
        let product = run("/usr/bin/sw_vers", ["-productVersion"])
        let build = run("/usr/bin/sw_vers", ["-buildVersion"])
        return (product.isEmpty ? "?" : product, build.isEmpty ? "?" : build)
    }

    static func rebuildTool() -> String {
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/kmutil") { return "kmutil" }
        if FileManager.default.isExecutableFile(atPath: "/usr/sbin/kextcache") { return "kextcache" }
        return "none"
    }

    static func items() -> [StatusItem] {
        let sip = sipDisabled()
        let os = macOSVersion()
        let tool = rebuildTool()
        let target = KextInstaller.targetDir
        let targetExists = FileManager.default.fileExists(atPath: target)

        return [
            StatusItem(
                title: "System Integrity Protection",
                value: sip.disabled ? "Disabled" : "Enabled",
                detail: sip.disabled ? "Kext installs permitted" : "Disable SIP to install kexts",
                ok: sip.disabled,
                systemImage: "lock.shield"),
            StatusItem(
                title: "macOS",
                value: os.product,
                detail: "Build \(os.build)",
                ok: true,
                systemImage: "desktopcomputer"),
            StatusItem(
                title: "Target Directory",
                value: targetExists ? "Ready" : "Missing",
                detail: target,
                ok: targetExists,
                systemImage: "folder"),
            StatusItem(
                title: "Kernel Cache Tool",
                value: tool == "none" ? "Not found" : tool,
                detail: tool == "none" ? "kmutil/kextcache unavailable" : "Used to rebuild caches",
                ok: tool != "none",
                systemImage: "gearshape.2")
        ]
    }
}

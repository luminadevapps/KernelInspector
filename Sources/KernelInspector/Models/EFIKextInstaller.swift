import Foundation

/// A mounted OpenCore EFI we can install kexts into.
struct OCTarget: Identifiable, Hashable {
    let id = UUID()
    let diskModel: String
    let mountPoint: String
    var configPath: String { mountPoint + "/EFI/OC/config.plist" }
    var kextsDir: String { mountPoint + "/EFI/OC/Kexts" }
    var label: String { "\(diskModel)  —  \(mountPoint)" }
}

/// Installs kexts the OpenCore way: copy into EFI/OC/Kexts and register in
/// config.plist → Kernel → Add. Handles nested plugin kexts (e.g. AppleHDA's
/// AppleHDAController / DspFuncLib / IOHDAFamily), which OpenCore requires as
/// their own entries. This is the method that works on Tahoe, where a
/// sealed system volume blocks /Library/Extensions installs.
enum EFIKextInstaller {

    /// Mounted OpenCore EFIs (those with a readable config.plist).
    static func targets() -> [OCTarget] {
        var out: [OCTarget] = []
        for d in Maintenance.physicalDisks() {
            if let mp = d.efi?.mountPoint,
               FileManager.default.fileExists(atPath: mp + "/EFI/OC/config.plist") {
                out.append(OCTarget(diskModel: d.model, mountPoint: mp))
            }
        }
        return out
    }

    /// Nested plugin .kext paths (relative to the parent), dependency-ordered.
    static func pluginRelPaths(kextURL: URL) -> [String] {
        let name = kextURL.lastPathComponent
        let plugins = kextURL.appendingPathComponent("Contents/PlugIns")
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: plugins.path) else { return [] }
        let kexts = items.filter { $0.hasSuffix(".kext") }
        let preferred = ["IOHDAFamily.kext", "DspFuncLib.kext", "AppleHDAController.kext"]
        let ordered = preferred.filter { kexts.contains($0) } + kexts.filter { !preferred.contains($0) }.sorted()
        return ordered.map { "\(name)/Contents/PlugIns/\($0)" }
    }

    private static func execRel(bundleAbsPath: String) -> String {
        let base = ((bundleAbsPath as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        let exe = bundleAbsPath + "/Contents/MacOS/" + base
        return FileManager.default.fileExists(atPath: exe) ? "Contents/MacOS/\(base)" : ""
    }

    private static func entry(bundlePath: String, execRel: String, comment: String) -> [String: Any] {
        [
            "Arch": "Any",
            "BundlePath": bundlePath,
            "Comment": comment,
            "Enabled": true,
            "ExecutablePath": execRel,
            "MaxKernel": "",
            "MinKernel": "",
            "PlistPath": "Contents/Info.plist"
        ]
    }

    /// Kernel→Add entries for a kext: plugins first (dependencies), main last.
    static func buildEntries(kextURL: URL) -> [[String: Any]] {
        let name = kextURL.lastPathComponent
        var entries: [[String: Any]] = []
        for rel in pluginRelPaths(kextURL: kextURL) {
            let abs = kextURL.deletingLastPathComponent().appendingPathComponent(rel).path
            entries.append(entry(bundlePath: rel, execRel: execRel(bundleAbsPath: abs),
                                 comment: "\(name) plugin"))
        }
        entries.append(entry(bundlePath: name, execRel: execRel(bundleAbsPath: kextURL.path),
                             comment: "\(name) — added by Kernel Inspector"))
        return entries
    }

    /// A human-readable preview of what will be added.
    static func previewEntries(kextURL: URL) -> [String] {
        buildEntries(kextURL: kextURL).map { ($0["BundlePath"] as? String) ?? "?" }
    }

    /// Copy the kext into EFI/OC/Kexts and append the entries to config.plist.
    /// Backs up config.plist first. Returns (ok, log).
    static func install(kextURL: URL, target: OCTarget) -> (ok: Bool, log: String) {
        guard var config = Maintenance.loadPlist(target.configPath),
              var kernel = config["Kernel"] as? [String: Any],
              var add = kernel["Add"] as? [[String: Any]] else {
            return (false, "Could not read \(target.configPath) (Kernel → Add).")
        }

        let name = kextURL.lastPathComponent
        let existing = Set(add.compactMap { $0["BundlePath"] as? String })
        let toAdd = buildEntries(kextURL: kextURL)
            .filter { !existing.contains(($0["BundlePath"] as? String) ?? "") }

        add.append(contentsOf: toAdd)
        kernel["Add"] = add
        config["Kernel"] = kernel

        let tmp = NSTemporaryDirectory() + "ki-config-new.plist"
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: tmp))
        } catch {
            return (false, "Failed to build updated config: \(error.localizedDescription)")
        }

        let stamp = Int(Date().timeIntervalSince1970)
        let backup = "\(target.configPath).ki-backup-\(stamp)"
        let cmd = [
            "/bin/cp '\(target.configPath)' '\(backup)'",
            "/bin/cp -R '\(kextURL.path)' '\(target.kextsDir)/'",
            "/bin/cp '\(tmp)' '\(target.configPath)'"
        ].joined(separator: " && ")

        var log = "Install \(name) → \(target.mountPoint)\n"
        log += "Adding \(toAdd.count) Kernel→Add entr\(toAdd.count == 1 ? "y" : "ies"):\n"
        for e in toAdd { log += "   • \((e["BundlePath"] as? String) ?? "?")\n" }
        log += "$ \(cmd)\n"

        let (ok, out) = PrivilegedShell.run(cmd)
        log += ok
            ? "✅ Done. Backup saved: \(backup)\nReboot for OpenCore to load it.\n\(out)"
            : "❌ \(out)"
        return (ok, log)
    }
}

import Foundation

/// Installs compiled `.aml` SSDTs into a mounted OpenCore EFI the same way
/// `EFIKextInstaller` installs kexts: copy the files into `EFI/OC/ACPI` and
/// register each one under `config.plist → ACPI → Add`. It can additionally
/// add the required `ACPI → Patch` renames (e.g. EC→EC0, _GPRW→XGPW) for the
/// tables that need them. config.plist is backed up first. Reuses `OCTarget`,
/// `Maintenance.loadPlist`, and `PrivilegedShell`.
enum SSDTInstaller {

    /// ACPI directory on a mounted OpenCore EFI.
    static func acpiDir(_ target: OCTarget) -> String { target.mountPoint + "/EFI/OC/ACPI" }

    /// A single `ACPI → Add` entry for one `.aml` file (Path is relative to
    /// `EFI/OC/ACPI`).
    private static func addEntry(fileName: String) -> [String: Any] {
        [
            "Comment": "\((fileName as NSString).deletingPathExtension) — added by Kernel Inspector",
            "Enabled": true,
            "Path": fileName
        ]
    }

    // MARK: - Previews

    /// Names (e.g. `SSDT-AWAC.aml`) that would be newly registered under
    /// ACPI→Add — i.e. those not already present.
    static func previewAdditions(amlURLs: [URL], target: OCTarget) -> [String] {
        let existing = existingAddPaths(target)
        return amlURLs.map { $0.lastPathComponent }.filter { !existing.contains($0) }
    }

    /// Rename comments that would be newly added under ACPI→Patch (those not
    /// already present with the same Find+Replace).
    static func previewRenameAdditions(renames: [ACPIRename], target: OCTarget) -> [String] {
        let patch = existingPatches(target)
        return renames.filter { !patchExists($0, in: patch) }.map { $0.comment }
    }

    // MARK: - Existing-state helpers

    private static func existingAddPaths(_ target: OCTarget) -> Set<String> {
        guard let config = Maintenance.loadPlist(target.configPath),
              let acpi = config["ACPI"] as? [String: Any],
              let add = acpi["Add"] as? [[String: Any]] else { return [] }
        return Set(add.compactMap { $0["Path"] as? String })
    }

    private static func existingPatches(_ target: OCTarget) -> [[String: Any]] {
        guard let config = Maintenance.loadPlist(target.configPath),
              let acpi = config["ACPI"] as? [String: Any],
              let patch = acpi["Patch"] as? [[String: Any]] else { return [] }
        return patch
    }

    private static func data(_ dict: [String: Any], _ key: String) -> Data {
        (dict[key] as? Data) ?? Data()
    }

    /// A patch is considered already present if an entry has the same Find and
    /// Replace bytes.
    private static func patchExists(_ rename: ACPIRename, in patch: [[String: Any]]) -> Bool {
        let find = Data(rename.find)
        let replace = Data(rename.paddedReplace)
        return patch.contains { data($0, "Find") == find && data($0, "Replace") == replace }
    }

    // MARK: - Install

    /// Copy the given `.aml` files into `EFI/OC/ACPI`, append any missing ones
    /// to `config.plist → ACPI → Add`, and add any missing `renames` to
    /// `ACPI → Patch`. Backs up config.plist first. Returns (ok, log).
    static func install(amlURLs: [URL],
                        renames: [ACPIRename] = [],
                        target: OCTarget) -> (ok: Bool, log: String) {
        guard !amlURLs.isEmpty else { return (false, "No compiled .aml files to install.") }

        guard var config = Maintenance.loadPlist(target.configPath) else {
            return (false, "Could not read \(target.configPath).")
        }

        // ACPI dict (create sub-keys if a minimal config lacks them).
        var acpi = (config["ACPI"] as? [String: Any]) ?? [:]

        // --- ACPI → Add -----------------------------------------------------
        var add = (acpi["Add"] as? [[String: Any]]) ?? []
        let existingAdd = Set(add.compactMap { $0["Path"] as? String })
        let newFiles = amlURLs.map { $0.lastPathComponent }.filter { !existingAdd.contains($0) }
        for f in newFiles { add.append(addEntry(fileName: f)) }
        acpi["Add"] = add

        // --- ACPI → Patch (renames) ----------------------------------------
        var patch = (acpi["Patch"] as? [[String: Any]]) ?? []
        var addedRenames: [String] = []
        for r in renames where !patchExists(r, in: patch) {
            patch.append(r.patchEntry())
            addedRenames.append("\(r.comment)  (\(r.findHex) → \(r.replaceHex))")
        }
        acpi["Patch"] = patch

        config["ACPI"] = acpi

        // Serialize updated config to a temp file.
        let tmp = NSTemporaryDirectory() + "ki-ssdt-config-new.plist"
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: tmp))
        } catch {
            return (false, "Failed to build updated config: \(error.localizedDescription)")
        }

        // Privileged command chain: mkdir ACPI, backup config, copy every .aml,
        // then write the new config.
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = "\(target.configPath).ki-backup-\(stamp)"
        var parts: [String] = []
        parts.append("/bin/mkdir -p '\(acpiDir(target))'")
        parts.append("/bin/cp '\(target.configPath)' '\(backup)'")
        for url in amlURLs { parts.append("/bin/cp '\(url.path)' '\(acpiDir(target))/'") }
        parts.append("/bin/cp '\(tmp)' '\(target.configPath)'")
        let cmd = parts.joined(separator: " && ")

        var log = "Install \(amlURLs.count) SSDT(s) → \(target.mountPoint)/EFI/OC/ACPI\n"
        if newFiles.isEmpty {
            log += "All SSDTs already registered under ACPI→Add; files refreshed.\n"
        } else {
            log += "Adding \(newFiles.count) ACPI→Add entr\(newFiles.count == 1 ? "y" : "ies"):\n"
            for f in newFiles { log += "   • \(f)\n" }
        }
        if addedRenames.isEmpty {
            if !renames.isEmpty { log += "ACPI→Patch renames already present; none added.\n" }
        } else {
            log += "Adding \(addedRenames.count) ACPI→Patch rename\(addedRenames.count == 1 ? "" : "s"):\n"
            for r in addedRenames { log += "   • \(r)\n" }
        }
        log += "$ \(cmd)\n"

        let (ok, out) = PrivilegedShell.run(cmd)
        log += ok
            ? "✅ Done. Backup saved: \(backup)\nReboot for OpenCore to load the new tables.\n\(out)"
            : "❌ \(out)"
        return (ok, log)
    }
}

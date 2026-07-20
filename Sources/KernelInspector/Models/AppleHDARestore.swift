import Foundation

/// Restores AppleHDA on macOS Tahoe (26), where Apple removed it. AppleHDA must
/// live in /System/Library/Extensions and be loaded via a KDK-based root patch —
/// it cannot be injected through OpenCore. This mirrors the documented
/// SimpleLoader / OCLP flow:
///   1. mount the System volume read-write
///   2. merge the matching KDK (brings kernel variants + AppleHDA)
///   3. install the chosen AppleHDA.kext into /S/L/E
///   4. kmutil install --update-all  (rebuild kernel collections)
///   5. bless --create-snapshot      (authorise the modified snapshot)
///
/// The current sealed snapshot is preserved, so a bad result is revertible from
/// macOS Recovery. This is inherently high-risk and cannot be undone from a
/// running system — callers must warn the user.
enum AppleHDARestore {

    struct Prereq: Identifiable {
        let id = UUID()
        let ok: Bool
        let title: String
        let detail: String
    }

    static func kdks() -> [String] { Maintenance.installedKDKs() }

    static func prereqs(kdk: String?, kext: URL?) -> [Prereq] {
        let sip = SystemStatus.sipDisabled().disabled
        let list = kdks()
        return [
            Prereq(ok: sip, title: "SIP permissive",
                   detail: sip ? "Kext installs permitted" : "Set csr-active-config to 03080000"),
            Prereq(ok: !list.isEmpty, title: "KDK installed",
                   detail: list.first ?? "Install the KDK matching your build"),
            Prereq(ok: kdk != nil, title: "KDK selected",
                   detail: kdk ?? "Choose a KDK below"),
            Prereq(ok: FileManager.default.fileExists(atPath: "/usr/bin/kmutil"),
                   title: "kmutil available", detail: "/usr/bin/kmutil")
        ]
    }

    /// AppleHDA path to install: the user's choice, else the KDK's own copy.
    static func resolvedKextPath(kdk: String, chosen: URL?) -> String? {
        if let c = chosen { return c.path }
        let inKDK = "/Library/Developer/KDKs/\(kdk)/System/Library/Extensions/AppleHDA.kext"
        return FileManager.default.fileExists(atPath: inKDK) ? inKDK : nil
    }

    /// The root-patch shell script (run as root from a temp file).
    ///
    /// Uses `mount -uw /` to remount the live root read-write in place — this is
    /// the correct method when authenticated-root is disabled (csr bit 0x800).
    /// Mounting the System device at a second point fails with "Resource busy".
    static func buildScript(kdk: String, kextPath: String?) -> String {
        let kextStep: String
        if let k = kextPath {
            kextStep = """
            echo '==> Installing AppleHDA.kext'
            /bin/cp -R '\(k)' "$MNT/System/Library/Extensions/"
            /usr/sbin/chown -R root:wheel "$MNT/System/Library/Extensions/AppleHDA.kext"
            /bin/chmod -R 755 "$MNT/System/Library/Extensions/AppleHDA.kext"
            """
        } else {
            kextStep = "echo '==> Using AppleHDA from the KDK merge'"
        }
        // Standard OCLP root-patch flow: mount the System volume at the reserved
        // update mountpoint, patch, rebuild, then bless CoreServices as a snapshot.
        // Note: `mount` can fail with "Resource busy" (code 75) if the volume is
        // held — this also affects OCLP; the fix is to reboot and retry right away.
        return """
        set -e
        KDK='/Library/Developer/KDKs/\(kdk)'
        MNT=/System/Volumes/Update/mnt1
        SYSDEV="$(/usr/sbin/diskutil info / | /usr/bin/awk -F': *' '/Device Node/{print $2}' | /usr/bin/tr -d ' ')"
        echo "==> System device: $SYSDEV"
        /sbin/umount "$MNT" 2>/dev/null || /usr/sbin/diskutil unmount force "$MNT" 2>/dev/null || true
        echo '==> Mounting the System volume read-write at mnt1…'
        /sbin/mount -o nobrowse,rw -t apfs "$SYSDEV" "$MNT"
        echo '==> Merging KDK System (kernels + AppleHDA)…'
        /usr/bin/ditto "$KDK/System" "$MNT/System"
        \(kextStep)
        echo '==> Rebuilding kernel collections (kmutil, may take several minutes)…'
        /usr/bin/kmutil install --volume-root "$MNT" --update-all
        echo '==> Authorising snapshot (bless)…'
        /usr/sbin/bless --folder "$MNT/System/Library/CoreServices" --bootefi --create-snapshot
        echo '==> Complete. Reboot required.'
        """
    }

    /// Writes the script to a temp file and runs it with administrator privileges.
    static func run(kdk: String, kextPath: String?) -> (ok: Bool, log: String) {
        let script = buildScript(kdk: kdk, kextPath: kextPath)
        let tmp = NSTemporaryDirectory() + "ki-restore-applehda.sh"
        do {
            try script.write(toFile: tmp, atomically: true, encoding: .utf8)
        } catch {
            return (false, "Could not write script: \(error.localizedDescription)")
        }
        let (ok, out) = PrivilegedShell.run("/bin/sh '\(tmp)'")
        return (ok, "$ sh (root)\n\(script)\n\n\(out)")
    }
}

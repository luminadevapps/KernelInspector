import Foundation
import AppKit

struct DiskPartition: Identifiable {
    let id: String            // diskXsY
    var volumeName: String
    var content: String       // Content type e.g. EFI, Apple_APFS
    var mountPoint: String?
    var isMounted: Bool { mountPoint != nil }
}

/// A physical disk with its partitions and (if present) EFI system partition,
/// modelled after "ESP Mounter".
struct PhysicalDisk: Identifiable {
    let id: String            // diskX
    var model: String
    var size: String
    var isInternal: Bool
    var partitions: [DiskPartition]
    var efi: DiskPartition?
    var osType: String        // macOS / Windows / …
    var hasOpenCore: Bool

    /// Non-empty volume labels for display (e.g. "SSD 860 · Z790").
    var labels: String {
        let names = partitions.map { $0.volumeName }.filter { !$0.isEmpty && $0 != "EFI" }
        return names.isEmpty ? "No Volume Label" : names.joined(separator: " · ")
    }
}

/// Hackintosh-style system-maintenance helpers built on `diskutil`.
/// Read operations are unprivileged; mutating ones go through PrivilegedShell.
enum Maintenance {

    // MARK: Process helpers

    static func runData(_ launch: String, _ args: [String]) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: launch) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return d
    }

    private static func infoPlist(_ id: String) -> [String: Any]? {
        guard let d = runData("/usr/sbin/diskutil", ["info", "-plist", id]) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any]
    }

    private static func humanSize(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useTB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    // MARK: Disk enumeration (ESP Mounter style)

    static func physicalDisks() -> [PhysicalDisk] {
        guard let data = runData("/usr/sbin/diskutil", ["list", "-plist", "physical"]),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let all = plist["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }

        var disks: [PhysicalDisk] = []
        for d in all {
            let diskID = d["DeviceIdentifier"] as? String ?? ""
            let sizeBytes = (d["Size"] as? NSNumber)?.int64Value ?? 0

            var parts: [DiskPartition] = []
            var efi: DiskPartition?
            var osType = "Unknown"
            for p in (d["Partitions"] as? [[String: Any]] ?? []) {
                let pid = p["DeviceIdentifier"] as? String ?? ""
                let vname = p["VolumeName"] as? String ?? ""
                let content = p["Content"] as? String ?? ""
                let mpRaw = p["MountPoint"] as? String
                let mp = (mpRaw?.isEmpty == false) ? mpRaw : nil
                let part = DiskPartition(id: pid, volumeName: vname, content: content, mountPoint: mp)
                parts.append(part)
                if content == "EFI" { efi = part }
                if content == "Apple_APFS" || content == "Apple_HFS" || content == "Apple_CoreStorage" {
                    osType = "macOS"
                } else if content.contains("Microsoft") || content.contains("Windows") || content.contains("NTFS") {
                    if osType == "Unknown" { osType = "Windows" }
                }
            }

            let info = infoPlist(diskID)
            let model = (info?["MediaName"] as? String) ?? diskID
            let isInternal = (info?["Internal"] as? Bool) ?? true

            var disk = PhysicalDisk(id: diskID, model: model, size: humanSize(sizeBytes),
                                    isInternal: isInternal, partitions: parts, efi: efi,
                                    osType: osType, hasOpenCore: false)
            if let mp = efi?.mountPoint {
                let fm = FileManager.default
                disk.hasOpenCore = fm.fileExists(atPath: mp + "/EFI/OC")
                    || fm.fileExists(atPath: mp + "/EFI/OC/OpenCore.efi")
            }
            disks.append(disk)
        }
        return disks
    }

    static func mountCommand(_ partitionID: String) -> String { "/usr/sbin/diskutil mount /dev/\(partitionID)" }
    static func unmountCommand(_ partitionID: String) -> String { "/usr/sbin/diskutil unmount /dev/\(partitionID)" }

    static func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    // MARK: Kernel Debug Kits

    static let kdkDir = "/Library/Developer/KDKs"

    static func installedKDKs() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: kdkDir))?
            .filter { $0.hasSuffix(".kdk") }.sorted() ?? []
    }

    static func uninstallKDKCommand(_ name: String) -> String {
        "/bin/rm -rf '\(kdkDir)/\(name)'"
    }

    static func openKDKDownloads() {
        if let url = URL(string: "https://developer.apple.com/download/all/?q=Kernel%20Debug%20Kit") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: APFS snapshots

    static func snapshots() -> [String] {
        let out = SystemStatus.run("/usr/sbin/diskutil", ["apfs", "listSnapshots", "/"])
        var names: [String] = []
        for raw in out.split(separator: "\n") {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Name:") {
                let n = line.components(separatedBy: "Name:").last?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if !n.isEmpty { names.append(n) }
            }
        }
        return names
    }

    static func deleteSnapshotCommand(_ name: String) -> String {
        "/usr/sbin/diskutil apfs deleteSnapshot / -name '\(name)'"
    }

    // MARK: OpenCore config.plist

    /// Path to config.plist on a mounted OpenCore EFI, if present.
    static func configPlistPath(mountPoint: String?) -> String? {
        guard let mp = mountPoint else { return nil }
        let p = mp + "/EFI/OC/config.plist"
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    static func loadPlist(_ path: String) -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any]
    }

    /// The kexts declared under Kernel → Add in an OpenCore config.
    static func configKexts(_ plist: [String: Any]) -> [(name: String, enabled: Bool)] {
        guard let kernel = plist["Kernel"] as? [String: Any],
              let add = kernel["Add"] as? [[String: Any]] else { return [] }
        return add.map { entry in
            let path = (entry["BundlePath"] as? String) ?? "?"
            let enabled = (entry["Enabled"] as? Bool) ?? false
            return (path, enabled)
        }
    }

    static func openExternally(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

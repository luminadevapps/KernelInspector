import Foundation

/// An OpenCore `ACPI → Patch` rename (Base empty, Count 0) that a generated
/// SSDT depends on. Some maintenance SSDTs only work once a matching ACPI
/// rename is present — e.g. `SSDT-EC` needs `EC → EC0`, `SSDT-GPRW` needs
/// `_GPRW → XGPW`. This models those so the installer can add them
/// automatically instead of the user editing config.plist by hand.
struct ACPIRename: Identifiable, Hashable {
    let id = UUID()
    let comment: String
    let find: [UInt8]
    let replace: [UInt8]

    /// OpenCore requires Find and Replace to be the same length. When the
    /// replacement name is shorter (e.g. `XGPW` vs `_GPRW`), pad it with
    /// trailing `0x00` so the two byte-strings match in size.
    var paddedReplace: [UInt8] {
        guard replace.count < find.count else { return replace }
        return replace + Array(repeating: 0, count: find.count - replace.count)
    }

    var findHex: String { find.map { String(format: "%02X", $0) }.joined() }
    var replaceHex: String { paddedReplace.map { String(format: "%02X", $0) }.joined() }

    /// A complete config.plist `ACPI → Patch` entry.
    func patchEntry() -> [String: Any] {
        [
            "Base": "",
            "BaseSkip": 0,
            "Comment": "\(comment) — added by Kernel Inspector",
            "Count": 0,
            "Enabled": true,
            "Find": Data(find),
            "Limit": 0,
            "Mask": Data(),
            "OemTableId": Data(),
            "Replace": Data(paddedReplace),
            "ReplaceMask": Data(),
            "Skip": 0,
            "TableLength": 0,
            "TableSignature": Data()
        ]
    }
}

extension ACPIRename {

    // Known renames. Byte values follow the standard OpenCore patches.
    static let ecToEC0 = ACPIRename(
        comment: "Rename EC to EC0",
        find:    [0x45, 0x43, 0x5F, 0x5F],   // "EC__"
        replace: [0x45, 0x43, 0x30, 0x00])   // "EC0\0"

    static let gprwToXGPW = ACPIRename(
        comment: "Rename _GPRW to XGPW",
        find:    [0x5F, 0x47, 0x50, 0x52, 0x57],   // "_GPRW"
        replace: [0x58, 0x47, 0x50, 0x57])         // "XGPW" (padded → "XGPW\0")

    /// Maps a generated SSDT filename to the rename(s) it requires. Extend this
    /// table as new tables that need renames are added.
    static func requiredFor(amlFileName: String) -> [ACPIRename] {
        switch amlFileName {
        case "SSDT-EC.aml":   return [.ecToEC0]
        case "SSDT-GPRW.aml": return [.gprwToXGPW]
        default:              return []
        }
    }

    /// All renames required by a set of generated `.aml` file names, de-duped.
    static func required(forAMLNames names: [String]) -> [ACPIRename] {
        var seen = Set<String>()
        var out: [ACPIRename] = []
        for n in names {
            for r in requiredFor(amlFileName: n) where seen.insert(r.findHex + ">" + r.replaceHex).inserted {
                out.append(r)
            }
        }
        return out
    }
}

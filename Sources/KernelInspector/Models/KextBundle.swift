import Foundation

/// Represents an opened target: either a `.kext` bundle or a lone binary file.
struct KextTarget {
    let sourceURL: URL           // what the user picked (.kext dir or a file)
    let binaryURL: URL           // the actual Mach-O file to parse
    let infoPlist: [String: Any]?
    let isBundle: Bool

    var displayName: String { sourceURL.lastPathComponent }

    var bundleIdentifier: String? { infoPlist?["CFBundleIdentifier"] as? String }
    var bundleVersion: String? { infoPlist?["CFBundleVersion"] as? String }

    /// Flattened, sorted key/value pairs for display.
    var plistRows: [(String, String)] {
        guard let dict = infoPlist else { return [] }
        return KextTarget.flatten(dict).sorted { $0.0 < $1.0 }
    }

    static func flatten(_ dict: [String: Any], prefix: String = "") -> [(String, String)] {
        var rows: [(String, String)] = []
        for (k, v) in dict {
            let key = prefix.isEmpty ? k : "\(prefix).\(k)"
            if let sub = v as? [String: Any] {
                rows += flatten(sub, prefix: key)
            } else if let arr = v as? [Any] {
                rows.append((key, "[\(arr.count) items]"))
                for (i, item) in arr.enumerated() {
                    if let subDict = item as? [String: Any] {
                        rows += flatten(subDict, prefix: "\(key)[\(i)]")
                    } else {
                        rows.append(("\(key)[\(i)]", String(describing: item)))
                    }
                }
            } else {
                rows.append((key, String(describing: v)))
            }
        }
        return rows
    }

    /// Open a URL, resolving a `.kext` bundle down to its executable.
    static func open(_ url: URL) -> KextTarget? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }

        if isDir.boolValue && url.pathExtension == "kext" {
            let contents = url.appendingPathComponent("Contents")
            let plistURL = contents.appendingPathComponent("Info.plist")
            let plist = readPlist(plistURL)
            // Executable name from CFBundleExecutable, else Contents/MacOS/<first>
            var binary: URL?
            if let exec = plist?["CFBundleExecutable"] as? String {
                binary = contents.appendingPathComponent("MacOS/\(exec)")
            }
            if binary == nil || !fm.fileExists(atPath: binary!.path) {
                let macos = contents.appendingPathComponent("MacOS")
                binary = (try? fm.contentsOfDirectory(at: macos, includingPropertiesForKeys: nil))?.first
            }
            guard let bin = binary else { return nil }
            return KextTarget(sourceURL: url, binaryURL: bin, infoPlist: plist, isBundle: true)
        }

        // Plain file — but maybe it has an adjacent Info.plist (loose kext layout).
        return KextTarget(sourceURL: url, binaryURL: url, infoPlist: nil, isBundle: false)
    }

    private static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

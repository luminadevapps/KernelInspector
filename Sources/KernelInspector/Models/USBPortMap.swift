import Foundation

/// One USB port under a controller (an AppleUSBHostPort nub).
struct USBPort: Identifiable {
    let id = UUID()
    let name: String            // HS01, SS01, SSP1, USBC…
    let locationID: UInt32
    let portNumber: Int         // XHCI port index (1-based)
    let detectedConnector: Int  // UsbConnector from ACPI _UPC, -1 if none
    var enabled: Bool = true
    var type: Int               // editable connector type used for export

    var kind: String {
        if name.hasPrefix("SSP") { return "USB4 / TB (SSP)" }
        if name.hasPrefix("SS")  { return "USB3 (SS)" }
        if name.hasPrefix("HS")  { return "USB2 (HS)" }
        if name.hasPrefix("USB") || name.hasPrefix("USR") || name.hasPrefix("TypeC") { return "Type-C" }
        return "port"
    }
}

/// A USB host controller with its ports.
struct USBController: Identifiable {
    let id = UUID()
    let name: String            // XHCI, XHC3
    let ioClass: String
    let locationID: UInt32
    var ports: [USBPort]

    var overLimit: Bool { ports.count > 15 }
    var enabledCount: Int { ports.filter { $0.enabled }.count }
}

/// USB connector types (ACPI _UPC / Apple UsbConnector values).
enum USBConnectorType {
    static let options: [(Int, String)] = [
        (0,   "0 · USB2 Type-A"),
        (3,   "3 · USB3 Type-A"),
        (9,   "9 · Type-C (with switch)"),
        (10,  "10 · Type-C (no switch)"),
        (255, "255 · Internal"),
    ]
    static func label(_ v: Int) -> String {
        options.first { $0.0 == v }?.1 ?? "\(v)"
    }
    /// Sensible default from a port name when ACPI didn't specify one.
    static func defaultFor(name: String) -> Int {
        if name.hasPrefix("SSP") { return 3 }
        if name.hasPrefix("SS")  { return 3 }
        if name.hasPrefix("HS")  { return 0 }
        if name.hasPrefix("USB") || name.hasPrefix("USR") || name.hasPrefix("TypeC") { return 9 }
        return 0
    }
}

// MARK: - Reader (live ioreg)

enum USBPortReader {

    /// Reads USB controllers and their ports from the live registry via ioreg.
    static func read() -> [USBController] {
        let out = run("/usr/sbin/ioreg", ["-c", "AppleUSBHostController", "-r", "-l", "-w", "0"])
        guard !out.isEmpty else { return [] }
        return parse(out)
    }

    static func model() -> String {
        let m = run("/usr/sbin/sysctl", ["-n", "hw.model"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? "iMacPro1,1" : m
    }

    // MARK: Parse

    static func parse(_ text: String) -> [USBController] {
        var controllers: [USBController] = []
        var ctrlIndex: Int? = nil
        var ctrlIndent = -1
        var portIndent = -1
        var portIndex: Int? = nil

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let obj = parseObject(line) {
                let (indent, name, cls) = obj
                if cls.contains("XHCI") && !cls.contains("Port") {
                    // A controller.
                    controllers.append(USBController(name: name, ioClass: cls,
                                                     locationID: 0, ports: []))
                    ctrlIndex = controllers.count - 1
                    ctrlIndent = indent
                    portIndent = -1
                    portIndex = nil
                } else if let ci = ctrlIndex, cls.contains("HostPort") || isPortName(name) {
                    if portIndent == -1 && indent > ctrlIndent { portIndent = indent }
                    if indent == portIndent {
                        let p = USBPort(name: name, locationID: 0, portNumber: 0,
                                        detectedConnector: -1,
                                        type: USBConnectorType.defaultFor(name: name))
                        controllers[ci].ports.append(p)
                        portIndex = controllers[ci].ports.count - 1
                    } else {
                        portIndex = nil   // deeper (hub port / device) — ignore
                    }
                } else {
                    portIndex = nil
                }
            } else if let (key, val) = parseProperty(line) {
                guard let ci = ctrlIndex else { continue }
                if let pi = portIndex {
                    switch key {
                    case "UsbConnector":
                        if let n = intValue(val) {
                            controllers[ci].ports[pi] = withConnector(controllers[ci].ports[pi], n)
                        }
                    case "port":
                        if let b = firstDataByte(val) {
                            controllers[ci].ports[pi] = withPortNumber(controllers[ci].ports[pi], Int(b))
                        }
                    case "locationID":
                        if let n = intValue(val) {
                            controllers[ci].ports[pi] = withLocation(controllers[ci].ports[pi], UInt32(truncatingIfNeeded: n))
                        }
                    default: break
                    }
                } else if key == "locationID", let n = intValue(val), controllers[ci].locationID == 0 {
                    controllers[ci] = withCtrlLocation(controllers[ci], UInt32(truncatingIfNeeded: n))
                }
            }
        }
        // Sort ports by location for a stable display.
        for i in controllers.indices {
            controllers[i].ports.sort { $0.locationID < $1.locationID }
        }
        return controllers.sorted { $0.locationID < $1.locationID }
    }

    // Mutating helpers (structs with `let` fields → rebuild).
    private static func withConnector(_ p: USBPort, _ c: Int) -> USBPort {
        USBPort(name: p.name, locationID: p.locationID, portNumber: p.portNumber,
                detectedConnector: c, enabled: p.enabled, type: c >= 0 ? c : p.type)
    }
    private static func withPortNumber(_ p: USBPort, _ n: Int) -> USBPort {
        USBPort(name: p.name, locationID: p.locationID, portNumber: n,
                detectedConnector: p.detectedConnector, enabled: p.enabled, type: p.type)
    }
    private static func withLocation(_ p: USBPort, _ l: UInt32) -> USBPort {
        USBPort(name: p.name, locationID: l, portNumber: p.portNumber,
                detectedConnector: p.detectedConnector, enabled: p.enabled, type: p.type)
    }
    private static func withCtrlLocation(_ c: USBController, _ l: UInt32) -> USBController {
        USBController(name: c.name, ioClass: c.ioClass, locationID: l, ports: c.ports)
    }

    // MARK: Line helpers

    /// Returns (indent, name, class) for an object line `… +-o NAME@ADDR  <class CLASS, …>`.
    private static func parseObject(_ line: String) -> (Int, String, String)? {
        guard let r = line.range(of: "+-o ") else { return nil }
        let indent = line.distance(from: line.startIndex, to: r.lowerBound)
        let rest = String(line[r.upperBound...])
        // name = up to '@' or up to "  <"
        var name = rest
        if let at = rest.firstIndex(of: "@") {
            name = String(rest[..<at])
        } else if let lt = rest.range(of: "  <") {
            name = String(rest[..<lt.lowerBound])
        }
        name = name.trimmingCharacters(in: .whitespaces)
        var cls = ""
        if let cr = rest.range(of: "<class ") {
            let tail = rest[cr.upperBound...]
            if let comma = tail.firstIndex(of: ",") { cls = String(tail[..<comma]) }
        }
        return (indent, name, cls)
    }

    /// Returns (key, value) for a property line `… "KEY" = VALUE`.
    private static func parseProperty(_ line: String) -> (String, String)? {
        guard let firstQuote = line.firstIndex(of: "\"") else { return nil }
        let afterFirst = line.index(after: firstQuote)
        guard let secondQuote = line[afterFirst...].firstIndex(of: "\"") else { return nil }
        let key = String(line[afterFirst..<secondQuote])
        guard let eq = line[secondQuote...].range(of: " = ") else { return nil }
        let val = String(line[eq.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (key, val)
    }

    private static func intValue(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("0x") || t.hasPrefix("0X") { return Int(t.dropFirst(2), radix: 16) }
        return Int(t)
    }

    /// First byte of an ioreg data value like `<01000000>`.
    private static func firstDataByte(_ s: String) -> UInt8? {
        guard let lt = s.firstIndex(of: "<"), let gt = s.firstIndex(of: ">"), lt < gt else { return nil }
        let hex = s[s.index(after: lt)..<gt]
        let two = hex.prefix(2)
        return UInt8(two, radix: 16)
    }

    private static func isPortName(_ n: String) -> Bool {
        let prefixes = ["HS", "SS", "SSP", "USR", "USBC", "TypeC", "PRT"]
        return prefixes.contains { n.hasPrefix($0) }
    }

    private static func run(_ launch: String, _ args: [String]) -> String {
        guard FileManager.default.isExecutableFile(atPath: launch) else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: - USBPorts.kext exporter (Hackintool-style, codeless)

enum USBPortMapExporter {

    /// Builds a codeless USBPorts.kext that injects the enabled ports via
    /// AppleUSBHostMergeProperties. Matches each controller by its IONameMatch
    /// (e.g. XHCI) and the SMBIOS model. Returns the written .kext URL.
    static func export(controllers: [USBController], model: String,
                       to folder: URL, name: String = "USBPorts") throws -> URL {

        var personalities: [String: Any] = [:]
        for c in controllers {
            let enabled = c.ports.filter { $0.enabled }
            guard !enabled.isEmpty else { continue }
            var portsDict: [String: Any] = [:]
            var maxPort = 0
            for p in enabled {
                let num = p.portNumber > 0 ? p.portNumber : (portsDict.count + 1)
                portsDict[p.name] = [
                    "UsbConnector": p.type,
                    "port": Data([UInt8(num & 0xFF), 0, 0, 0]),
                    "comment": "\(p.name) (\(p.kind))"
                ]
                maxPort = max(maxPort, num)
            }
            personalities[c.name] = [
                "CFBundleIdentifier": "com.apple.driver.AppleUSBHostMergeProperties",
                "IOClass": "AppleUSBHostMergeProperties",
                "IOProviderClass": "AppleUSBHostController",
                "IONameMatch": c.name,
                "model": model,
                "IOProviderMergeProperties": [
                    "ports": portsDict,
                    "port-count": Data([UInt8(maxPort & 0xFF), 0, 0, 0])
                ]
            ]
        }

        let info: [String: Any] = [
            "CFBundleDevelopmentRegion": "English",
            "CFBundleIdentifier": "com.luminadevapps.\(name)",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": name,
            "CFBundlePackageType": "KEXT",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1.0",
            "CFBundleSignature": "????",
            "OSBundleRequired": "Root",
            "IOKitPersonalities": personalities
        ]

        let kextURL = folder.appendingPathComponent("\(name).kext")
        let contents = kextURL.appendingPathComponent("Contents")
        if FileManager.default.fileExists(atPath: kextURL.path) {
            try FileManager.default.removeItem(at: kextURL)
        }
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return kextURL
    }
}

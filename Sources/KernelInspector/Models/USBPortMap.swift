import Foundation

/// One USB port under a controller (an AppleUSBHostPort nub).
struct USBPort: Identifiable {
    let id = UUID()
    let name: String            // HS01, SS01, SSP1, USBC…
    var locationID: UInt32
    var portNumber: Int         // XHCI port index (1-based)
    var detectedConnector: Int  // UsbConnector from ACPI _UPC, -1 if none
    var enabled: Bool = true
    var type: Int               // editable connector type used for export

    /// Name of the device currently plugged into this port, if any.
    var attachedDevice: String? = nil
    /// A keyboard, mouse or other HID is live on this port right now.
    /// Disabling it in a map is how you end up with no way to type.
    var hasInputDevice: Bool = false

    var kind: String {
        if name.hasPrefix("SSP") { return "USB4 / TB (SSP)" }
        if name.hasPrefix("SS")  { return "USB3 (SS)" }
        if name.hasPrefix("HS")  { return "USB2 (HS)" }
        if name.hasPrefix("USB") || name.hasPrefix("USR") || name.hasPrefix("TypeC") { return "Type-C" }
        return "port"
    }

    /// The firmware told us this port's connector type via ACPI `_UPC`.
    var typeFromFirmware: Bool { detectedConnector >= 0 }
    /// No `_UPC` — whatever type we export is an assumption, not a reading.
    var typeIsGuess: Bool { detectedConnector < 0 }
    /// The chosen type contradicts what the firmware reported.
    var typeOverridesFirmware: Bool { detectedConnector >= 0 && type != detectedConnector }
    /// No real XHCI address was read; exporting this would be a fabrication.
    var hasRealPortNumber: Bool { portNumber > 0 }

    var occupancy: String {
        if hasInputDevice { return attachedDevice.map { "\($0) — INPUT DEVICE" } ?? "input device" }
        return attachedDevice ?? ""
    }
}

/// Port-count targets for an exported map.
///
/// macOS natively enumerates at most **15** ports per USB controller. Anything
/// above that is only reachable while the XHCI **port-limit patch** is applied
/// — an exported map does not by itself raise the cap. Offering 20/25/30 lets
/// you build a full map for a patched system (custom connector types across
/// every port) instead of being forced to throw ports away.
enum USBPortLimit {
    /// The cap macOS enforces without a port-limit patch.
    static let native = 15
    /// Selectable targets shown in the UI.
    static let options = [15, 20, 25, 30]

    /// Whether this target requires the port-limit patch to enumerate.
    static func needsPatch(_ limit: Int) -> Bool { limit > native }

    static func label(_ limit: Int) -> String {
        limit == native ? "\(limit) — macOS default" : "\(limit) — needs port-limit patch"
    }
}

/// A USB host controller with its ports.
struct USBController: Identifiable {
    let id = UUID()
    let name: String            // XHCI, XHC3
    let ioClass: String
    var locationID: UInt32
    var ports: [USBPort]

    /// More ports present than macOS enumerates unpatched.
    var exceedsNativeCap: Bool { ports.count > USBPortLimit.native }
    var enabledCount: Int { ports.filter { $0.enabled }.count }

    /// Real XHCI addresses of the ports we can currently see, sorted.
    var portAddresses: [Int] { ports.map { $0.portNumber }.filter { $0 > 0 }.sorted() }

    /// The visible ports have gaps in their addressing — numbers are missing
    /// inside the min…max range. Raw hardware enumerates contiguously, so gaps
    /// are the signature of a USB map kext that is already installed and pruning
    /// the port list down to a chosen subset. This matters because the port-limit
    /// patch cannot override an injected map: while such a map is loaded, macOS
    /// only ever reports the mapped ports no matter what the patch does. Seeing
    /// the raw ports again requires removing that map and rebooting.
    var looksAlreadyMapped: Bool {
        let a = portAddresses
        guard let lo = a.first, let hi = a.last else { return false }
        return (hi - lo + 1) > a.count
    }

    /// Enabled ports measured against the chosen export target.
    func isOver(_ limit: Int) -> Bool { enabledCount > limit }
    func overBy(_ limit: Int) -> Int { max(0, enabledCount - limit) }
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
    /// Fallback used only when ACPI `_UPC` gave us nothing. A port *name* is
    /// not evidence of how the port is wired: a name like USBC or TypeC used
    /// to produce type 9 (Type-C with orientation switch), which asks macOS to
    /// do switching on a port that may not support it and can stop the port
    /// enumerating at all. Fall back to plain Type-A instead — a port that
    /// works with reduced Type-C behaviour beats a port that is dead — and let
    /// `typeIsGuess` surface it so the user can correct it before exporting.
    static func defaultFor(name: String) -> Int {
        if name.hasPrefix("SSP") { return 3 }
        if name.hasPrefix("SS")  { return 3 }
        if name.hasPrefix("HS")  { return 0 }
        return 3
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
        // The last root port seen. Unlike `portIndex` this survives while we
        // walk the devices nested underneath it, so attached hardware can be
        // attributed back to the port it hangs off.
        var occupant: Int? = nil

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
                    occupant = nil
                } else if let ci = ctrlIndex, cls.contains("HostPort") || isPortName(name) {
                    if portIndent == -1 && indent > ctrlIndent { portIndent = indent }
                    if indent == portIndent {
                        let p = USBPort(name: name, locationID: 0, portNumber: 0,
                                        detectedConnector: -1,
                                        type: USBConnectorType.defaultFor(name: name))
                        controllers[ci].ports.append(p)
                        portIndex = controllers[ci].ports.count - 1
                        occupant = portIndex
                    } else {
                        portIndex = nil   // deeper (hub port) — not a root port
                    }
                } else {
                    // Anything nested below a root port: record what is plugged
                    // in, and whether it is an input device. This is what lets
                    // us refuse to disable the port holding the keyboard.
                    if let ci = ctrlIndex, let op = occupant,
                       portIndent > 0, indent > portIndent,
                       controllers[ci].ports.indices.contains(op) {
                        if cls.contains("IOUSBHostDevice"),
                           controllers[ci].ports[op].attachedDevice == nil {
                            controllers[ci].ports[op].attachedDevice = name
                        }
                        if cls.contains("HID") {
                            controllers[ci].ports[op].hasInputDevice = true
                        }
                    }
                    portIndex = nil
                }
            } else if let (key, val) = parseProperty(line) {
                guard let ci = ctrlIndex else { continue }
                if let pi = portIndex, controllers[ci].ports.indices.contains(pi) {
                    switch key {
                    case "UsbConnector":
                        if let n = intValue(val) {
                            controllers[ci].ports[pi].detectedConnector = n
                            if n >= 0 { controllers[ci].ports[pi].type = n }
                        }
                    case "port":
                        if let b = firstDataByte(val) {
                            controllers[ci].ports[pi].portNumber = Int(b)
                        }
                    case "locationID":
                        if let n = intValue(val) {
                            controllers[ci].ports[pi].locationID = UInt32(truncatingIfNeeded: n)
                        }
                    default: break
                    }
                } else if key == "locationID", let n = intValue(val), controllers[ci].locationID == 0 {
                    controllers[ci].locationID = UInt32(truncatingIfNeeded: n)
                }
            }
        }
        // Sort ports by location for a stable display.
        for i in controllers.indices {
            controllers[i].ports.sort { $0.locationID < $1.locationID }
        }
        return controllers.sorted { $0.locationID < $1.locationID }
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

// MARK: - Pre-export audit

/// One problem found by checking a proposed map against the live system.
///
/// `id` is derived from the contents, never a fresh UUID: these values are
/// rebuilt whenever the map changes, and a new identity each time would tell
/// SwiftUI the list is different on every pass and spin the view into a
/// re-render loop.
struct USBMapIssue: Identifiable {
    enum Severity: String { case blocking, warning }
    let severity: Severity
    let text: String
    var id: String { severity.rawValue + "|" + text }
    var isBlocking: Bool { severity == .blocking }
}

/// Checks a map *before* it is written, against a fresh reading of the machine.
///
/// A USB map is declarative: once injected, macOS treats the listed ports as
/// the whole truth and anything omitted stops working. That makes an unchecked
/// export capable of removing the keyboard from a running system, so the
/// dangerous cases are found here rather than discovered after a reboot.
enum USBMapAuditor {

    /// `live` is a snapshot taken at refresh time, passed in deliberately.
    /// Reading ioreg here would shell out to a subprocess, and this runs on
    /// every edit — it must stay cheap enough to call synchronously.
    static func audit(controllers: [USBController], limit: Int,
                      live: [USBController]) -> [USBMapIssue] {
        var issues: [USBMapIssue] = []

        for c in controllers {
            let enabled = c.ports.filter { $0.enabled }

            // Ports being dropped that have hardware on them right now.
            let droppedWithInput = c.ports.filter { !$0.enabled && $0.hasInputDevice }
            for p in droppedWithInput {
                issues.append(USBMapIssue(
                    severity: .blocking,
                    text: "\(c.name) · \(p.name) is disabled but has an INPUT DEVICE on it right now (\(p.attachedDevice ?? "HID")). Installing this map would leave you unable to type. Enable it, or move the device first."))
            }
            let droppedOccupied = c.ports.filter { !$0.enabled && !$0.hasInputDevice && $0.attachedDevice != nil }
            for p in droppedOccupied {
                issues.append(USBMapIssue(
                    severity: .warning,
                    text: "\(c.name) · \(p.name) is disabled but currently has \(p.attachedDevice ?? "a device") attached — it will stop working."))
            }

            // Never write a port address we did not actually read.
            let noAddress = enabled.filter { !$0.hasRealPortNumber }
            if !noAddress.isEmpty {
                let names = noAddress.map { $0.name }.joined(separator: ", ")
                issues.append(USBMapIssue(
                    severity: .blocking,
                    text: "\(c.name): no XHCI address was read for \(names). Exporting would invent one, which maps the wrong hardware. Re-read the controller, or disable those ports."))
            }

            // Connector types we assumed rather than read.
            let guessed = enabled.filter { $0.typeIsGuess }
            if !guessed.isEmpty {
                let names = guessed.map { $0.name }.joined(separator: ", ")
                issues.append(USBMapIssue(
                    severity: .warning,
                    text: "\(c.name): the firmware gave no _UPC for \(names), so their connector type is a guess. Verify against USBToolBox before trusting it."))
            }

            // Types the user set against what the firmware reports.
            let overridden = enabled.filter { $0.typeOverridesFirmware }
            for p in overridden {
                issues.append(USBMapIssue(
                    severity: .warning,
                    text: "\(c.name) · \(p.name): you set type \(p.type) but the firmware reports \(p.detectedConnector). Type 9/10 on a port that is not wired for Type-C can stop it enumerating."))
            }

            if c.isOver(limit) {
                issues.append(USBMapIssue(
                    severity: .blocking,
                    text: "\(c.name): \(c.enabledCount) ports enabled, over the \(limit) target."))
            }
            if enabled.isEmpty && !c.ports.isEmpty {
                issues.append(USBMapIssue(
                    severity: .blocking,
                    text: "\(c.name): every port is disabled — that would kill all USB on this controller."))
            }

            // Compare against the machine as it is right now.
            if let liveCtrl = live.first(where: { $0.name == c.name }) {
                let liveNames = Set(liveCtrl.ports.map { $0.name })
                let missing = enabled.filter { !liveNames.contains($0.name) }
                if !missing.isEmpty {
                    let names = missing.map { $0.name }.joined(separator: ", ")
                    issues.append(USBMapIssue(
                        severity: .blocking,
                        text: "\(c.name): \(names) are in the map but not present on this machine."))
                }
            } else {
                issues.append(USBMapIssue(
                    severity: .blocking,
                    text: "Controller \(c.name) is no longer present — refresh before exporting."))
            }
        }

        if USBPortLimit.needsPatch(limit) {
            issues.append(USBMapIssue(
                severity: .warning,
                text: "This map targets \(limit) ports. macOS enumerates only \(USBPortLimit.native) without the XHCI port-limit patch — keep that patch in config.plist or everything past \(USBPortLimit.native) goes dark."))
        }
        return issues
    }
}

// MARK: - USBPorts.kext exporter (Hackintool-style, codeless)

enum USBMapExportError: LocalizedError {
    case missingPortNumber(controller: String, port: String)

    var errorDescription: String? {
        switch self {
        case let .missingPortNumber(controller, port):
            return "\(controller) · \(port) has no XHCI address from ioreg. "
                 + "Refusing to export rather than invent one — refresh the "
                 + "controller, or disable that port."
        }
    }
}

enum USBPortMapExporter {

    /// Builds a codeless USBPorts.kext that injects the enabled ports via
    /// AppleUSBHostMergeProperties. Each personality binds to the controller's
    /// real provider class (AppleUSBXHCIPCI), filtered by IONameMatch (e.g. XHCI)
    /// and the SMBIOS model, and carries kUSBMuxEnabled plus the full port/type
    /// key set a working map needs. Returns the written .kext URL.
    static func export(controllers: [USBController], model: String,
                       to folder: URL, name: String = "USBPorts",
                       portCount limit: Int = USBPortLimit.native) throws -> URL {

        var personalities: [String: Any] = [:]
        for c in controllers {
            let enabled = c.ports.filter { $0.enabled }
            guard !enabled.isEmpty else { continue }
            var portsDict: [String: Any] = [:]
            var maxPort = 0
            for p in enabled {
                // Never invent an address. A fabricated port number points
                // macOS at hardware that isn't there, and the failure only
                // shows up after a reboot.
                guard p.portNumber > 0 else {
                    throw USBMapExportError.missingPortNumber(controller: c.name, port: p.name)
                }
                let num = p.portNumber
                let addr = Data([UInt8(num & 0xFF), 0, 0, 0])
                // A working map (USBToolBox / USBMap style) carries both the
                // connector *type* keys (UsbConnector + usb-port-type) and both
                // *address* keys (port + usb-port-number). Emitting only
                // UsbConnector + port is what makes some ports silently fail to
                // enumerate on injection.
                portsDict[p.name] = [
                    "UsbConnector": p.type,
                    "usb-port-type": p.type,
                    "port": addr,
                    "usb-port-number": addr,
                    "comment": "\(p.name) (\(p.kind))"
                ]
                maxPort = max(maxPort, num)
            }
            // The merge must attach to the controller's *real* provider class
            // (AppleUSBXHCIPCI for an Intel PCH XHCI), not the generic
            // AppleUSBHostController — the generic parent can bind the map to the
            // wrong nub so it never applies. Use the class ioreg actually
            // reported for this controller.
            let providerClass = c.ioClass.contains("XHCI") ? c.ioClass : "AppleUSBXHCIPCI"
            // port-count sizes the controller's internal port array AND is the
            // enumeration cap: this is why a target above 15 needs the XHCI
            // port-limit patch. Use the chosen "ports per controller" target so
            // the dropdown actually takes effect, but never drop below the
            // highest real address or a mapped port would be clipped off the end.
            let hardwareMax = max(maxPort, c.ports.map { $0.portNumber }.max() ?? maxPort)
            let portCount = max(limit, hardwareMax)
            personalities["\(model)-\(c.name)"] = [
                "CFBundleIdentifier": "com.apple.driver.AppleUSBHostMergeProperties",
                "IOClass": "AppleUSBHostMergeProperties",
                "IOProviderClass": providerClass,
                "IONameMatch": c.name,
                "model": model,
                "IOProviderMergeProperties": [
                    // Pairs each HS port with its SS companion so USB3 devices
                    // negotiate SuperSpeed. Required by working maps.
                    "kUSBMuxEnabled": true,
                    "ports": portsDict,
                    "port-count": Data([UInt8(portCount & 0xFF), 0, 0, 0])
                ]
            ]
        }

        let info: [String: Any] = [
            "CFBundleDevelopmentRegion": "English",
            "CFBundleIdentifier": "com.luminadevapps.\(name)",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": name,
            "CFBundlePackageType": "KEXT",
            "CFBundleShortVersionString": "1.1",
            "CFBundleVersion": "1.1",
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

// MARK: - Importer (load the full port set from an existing map kext)

enum USBMapImportError: LocalizedError {
    case unreadable
    case noPersonalities
    case noPorts

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "Could not read an Info.plist from that file. Pick a USB map .kext bundle (USBMap.kext / USBPorts.kext) or its Info.plist."
        case .noPersonalities:
            return "That kext has no IOKitPersonalities — it is not a USB port map."
        case .noPorts:
            return "No ports were found in that map."
        }
    }
}

/// Loads controllers and their ports from an existing codeless USB map kext
/// (USBMap.kext, USBPorts.kext, USBToolBox output).
///
/// Live ioreg only reports the ports the currently-installed map exposes — at
/// most 15 without the port-limit patch. A map file, by contrast, lists *every*
/// port the author mapped, including ones left disabled. Importing it gives the
/// full real port set (real addresses, real connector types) to edit against,
/// so a larger map can be built without first removing the installed map and
/// rebooting. Nothing here is fabricated: every address comes from the file.
enum USBPortMapImporter {

    static func importKext(at url: URL) throws -> (controllers: [USBController], model: String) {
        // Accept either a .kext bundle or a direct Info.plist.
        var plistURL = url
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            plistURL = url.appendingPathComponent("Contents/Info.plist")
        }
        guard let data = try? Data(contentsOf: plistURL),
              let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        else { throw USBMapImportError.unreadable }

        guard let personalities = root["IOKitPersonalities"] as? [String: Any], !personalities.isEmpty else {
            throw USBMapImportError.noPersonalities
        }

        // One controller per IONameMatch. A map often carries the same ports
        // under several SMBIOS models (MacPro7,1, iMac20,2, …); those are the
        // same physical controller, so collapse them and remember the models.
        var byController: [String: USBController] = [:]
        var order: [String] = []
        var modelsSeen: [String] = []

        for (key, value) in personalities {
            guard let pers = value as? [String: Any] else { continue }
            let name = (pers["IONameMatch"] as? String)
                ?? key.split(separator: "-").last.map(String.init)
                ?? key
            let ioClass = (pers["IOProviderClass"] as? String) ?? "AppleUSBXHCIPCI"
            if let m = pers["model"] as? String, !modelsSeen.contains(m) { modelsSeen.append(m) }

            guard let mp = pers["IOProviderMergeProperties"] as? [String: Any],
                  let ports = mp["ports"] as? [String: Any] else { continue }

            var built: [USBPort] = []
            for (portName, raw) in ports {
                guard let info = raw as? [String: Any] else { continue }
                // Enabled entries carry `port`; USBMap disables a port by
                // prefixing its address key with `#`, so fall back to `#port`
                // and mark the port disabled when only that is present.
                let activeAddr = decodeInt(info["port"])
                let disabledAddr = decodeInt(info["#port"])
                guard let addr = activeAddr ?? disabledAddr else { continue }
                let type = decodeInt(info["UsbConnector"])
                    ?? decodeInt(info["usb-port-type"])
                    ?? USBConnectorType.defaultFor(name: portName)
                built.append(USBPort(
                    name: portName,
                    locationID: 0,
                    portNumber: addr,
                    // Type came from a real map, so treat it as known, not a
                    // guess — otherwise every row would flag a guess warning.
                    detectedConnector: type,
                    enabled: activeAddr != nil,
                    type: type))
            }
            guard !built.isEmpty else { continue }
            built.sort { $0.portNumber < $1.portNumber }

            if var existing = byController[name] {
                // Same controller under another model — keep the fuller list.
                if built.count > existing.ports.count {
                    existing.ports = built
                    byController[name] = existing
                }
            } else {
                byController[name] = USBController(name: name, ioClass: ioClass,
                                                   locationID: 0, ports: built)
                order.append(name)
            }
        }

        let controllers = order.compactMap { byController[$0] }
        guard !controllers.isEmpty else { throw USBMapImportError.noPorts }

        // Prefer the model matching this machine; else the first in the file.
        let live = USBPortReader.model()
        let model = modelsSeen.contains(live) ? live : (modelsSeen.first ?? live)
        return (controllers, model)
    }

    /// Decodes a port address / connector value that may be stored as a 4-byte
    /// little-endian data blob or as a plain integer.
    private static func decodeInt(_ v: Any?) -> Int? {
        if let d = v as? Data {
            var n = 0
            for (i, b) in d.prefix(4).enumerated() { n |= Int(b) << (8 * i) }
            return n
        }
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }
}

import Foundation

// MARK: - Constants

enum MachOMagic {
    static let magic32: UInt32   = 0xfeedface
    static let cigam32: UInt32   = 0xcefaedfe
    static let magic64: UInt32   = 0xfeedfacf
    static let cigam64: UInt32   = 0xcffaedfe
    static let fatMagic: UInt32  = 0xcafebabe
    static let fatCigam: UInt32  = 0xbebafeca
    static let fatMagic64: UInt32 = 0xcafebabf
    static let fatCigam64: UInt32 = 0xbfbafeca
}

enum LoadCommand: UInt32 {
    case segment64  = 0x19   // LC_SEGMENT_64
    case symtab     = 0x2    // LC_SYMTAB
    case dysymtab   = 0xb    // LC_DYSYMTAB
    case uuid       = 0x1b   // LC_UUID
    case idDylib    = 0xd    // LC_ID_DYLIB
    case loadDylib  = 0xc    // LC_LOAD_DYLIB
    case buildVersion = 0x32 // LC_BUILD_VERSION
}

/// A CPU type -> architecture name mapping (subset relevant to kexts).
func cpuName(_ type: Int32) -> String {
    switch type {
    case 0x0100000c: return "arm64"
    case 0x0000000c: return "arm"
    case 0x01000007: return "x86_64"
    case 0x00000007: return "i386"
    default:         return String(format: "cpu(0x%x)", UInt32(bitPattern: type))
    }
}

func fileTypeName(_ t: UInt32) -> String {
    switch t {
    case 0x1: return "OBJECT"
    case 0x2: return "EXECUTE"
    case 0x6: return "DYLIB"
    case 0x8: return "BUNDLE"   // kexts are typically MH_BUNDLE
    case 0xb: return "KEXT_BUNDLE"
    default:  return "type(\(t))"
    }
}

// MARK: - Model types

struct MachSection: Identifiable {
    let id = UUID()
    let segment: String
    let name: String
    let addr: UInt64
    let size: UInt64
    let offset: UInt32
    let flags: UInt32
    var isText: Bool { segment == "__TEXT" && name == "__text" }
}

struct MachSegment: Identifiable {
    let id = UUID()
    let name: String
    let vmaddr: UInt64
    let vmsize: UInt64
    let fileoff: UInt64
    let filesize: UInt64
    var sections: [MachSection]
}

struct Dependency: Identifiable {
    let id = UUID()
    let name: String
    let current: String
}

/// A parsed Mach-O image (one architecture slice).
struct MachOImage {
    var arch: String = ""
    var fileType: String = ""
    var flags: UInt32 = 0
    var is64: Bool = true
    var sliceOffset: Int = 0          // offset of this slice inside the file (FAT)
    var segments: [MachSegment] = []
    var sections: [MachSection] = []
    var symbols: [Symbol] = []
    var dependencies: [Dependency] = []
    var uuid: String = ""

    var textSection: MachSection? { sections.first(where: { $0.isText }) }
}

// MARK: - Parser

enum MachOParser {

    /// Parse the first native slice of a Mach-O / FAT binary.
    static func parse(_ data: Data) -> MachOImage? {
        guard data.count >= 4 else { return nil }
        let magic = ByteReader(data).peek(UInt32.self, at: 0) ?? 0

        switch magic {
        case MachOMagic.fatMagic, MachOMagic.fatCigam,
             MachOMagic.fatMagic64, MachOMagic.fatCigam64:
            return parseFat(data, magic: magic)
        case MachOMagic.magic64, MachOMagic.magic32:
            return parseThin(data, sliceOffset: 0, littleEndian: true)
        case MachOMagic.cigam64, MachOMagic.cigam32:
            return parseThin(data, sliceOffset: 0, littleEndian: false)
        default:
            return nil
        }
    }

    private static func parseFat(_ data: Data, magic: UInt32) -> MachOImage? {
        // FAT headers are always big-endian.
        let is64 = (magic == MachOMagic.fatMagic64 || magic == MachOMagic.fatCigam64)
        var r = ByteReader(data, offset: 4, bigEndian: true)
        guard let nfat = r.read(UInt32.self) else { return nil }

        struct Slice { var cputype: Int32; var offset: UInt64 }
        var slices: [Slice] = []
        for _ in 0..<nfat {
            guard let cputype = r.read(Int32.self) else { break }
            _ = r.read(Int32.self) // cpusubtype
            let offset: UInt64
            if is64 {
                offset = r.read(UInt64.self) ?? 0
                _ = r.read(UInt64.self) // size
                _ = r.read(UInt32.self) // align
                _ = r.read(UInt32.self) // reserved
            } else {
                offset = UInt64(r.read(UInt32.self) ?? 0)
                _ = r.read(UInt32.self) // size
                _ = r.read(UInt32.self) // align
            }
            slices.append(Slice(cputype: cputype, offset: offset))
        }
        // Prefer arm64, else x86_64, else first.
        let preferred = slices.first(where: { cpuName($0.cputype) == "arm64" })
            ?? slices.first(where: { cpuName($0.cputype) == "x86_64" })
            ?? slices.first
        guard let s = preferred else { return nil }
        let sliceMagic = ByteReader(data).peek(UInt32.self, at: Int(s.offset)) ?? 0
        let le = (sliceMagic == MachOMagic.magic64 || sliceMagic == MachOMagic.magic32)
        return parseThin(data, sliceOffset: Int(s.offset), littleEndian: le)
    }

    private static func parseThin(_ data: Data, sliceOffset: Int, littleEndian: Bool) -> MachOImage? {
        var img = MachOImage()
        img.sliceOffset = sliceOffset
        var r = ByteReader(data, offset: sliceOffset, bigEndian: !littleEndian)

        guard let magic = r.read(UInt32.self) else { return nil }
        img.is64 = (magic == MachOMagic.magic64 || magic == MachOMagic.cigam64)
        guard let cputype = r.read(Int32.self) else { return nil }
        _ = r.read(Int32.self) // cpusubtype
        guard let filetype = r.read(UInt32.self) else { return nil }
        guard let ncmds = r.read(UInt32.self) else { return nil }
        _ = r.read(UInt32.self) // sizeofcmds
        guard let flags = r.read(UInt32.self) else { return nil }
        if img.is64 { _ = r.read(UInt32.self) } // reserved

        img.arch = cpuName(cputype)
        img.fileType = fileTypeName(filetype)
        img.flags = flags

        var symtabOff: UInt32 = 0, nsyms: UInt32 = 0, stroff: UInt32 = 0, strsize: UInt32 = 0

        for _ in 0..<ncmds {
            let cmdStart = r.offset
            guard let cmd = r.read(UInt32.self), let cmdSize = r.read(UInt32.self), cmdSize > 0 else { break }

            switch LoadCommand(rawValue: cmd) {
            case .segment64:
                let segName = r.readFixedString(16)
                let vmaddr = r.read(UInt64.self) ?? 0
                let vmsize = r.read(UInt64.self) ?? 0
                let fileoff = r.read(UInt64.self) ?? 0
                let filesize = r.read(UInt64.self) ?? 0
                _ = r.read(UInt32.self) // maxprot
                _ = r.read(UInt32.self) // initprot
                let nsects = r.read(UInt32.self) ?? 0
                _ = r.read(UInt32.self) // flags
                var sects: [MachSection] = []
                for _ in 0..<nsects {
                    let sName = r.readFixedString(16)
                    let sSeg = r.readFixedString(16)
                    let addr = r.read(UInt64.self) ?? 0
                    let size = r.read(UInt64.self) ?? 0
                    let off = r.read(UInt32.self) ?? 0
                    _ = r.read(UInt32.self) // align
                    _ = r.read(UInt32.self) // reloff
                    _ = r.read(UInt32.self) // nreloc
                    let sflags = r.read(UInt32.self) ?? 0
                    _ = r.read(UInt32.self) // reserved1
                    _ = r.read(UInt32.self) // reserved2
                    _ = r.read(UInt32.self) // reserved3
                    let sec = MachSection(segment: sSeg.isEmpty ? segName : sSeg,
                                          name: sName, addr: addr, size: size,
                                          offset: off, flags: sflags)
                    sects.append(sec)
                    img.sections.append(sec)
                }
                img.segments.append(MachSegment(name: segName, vmaddr: vmaddr, vmsize: vmsize,
                                                fileoff: fileoff, filesize: filesize, sections: sects))
            case .symtab:
                symtabOff = r.read(UInt32.self) ?? 0
                nsyms = r.read(UInt32.self) ?? 0
                stroff = r.read(UInt32.self) ?? 0
                strsize = r.read(UInt32.self) ?? 0
            case .uuid:
                var bytes: [UInt8] = []
                for _ in 0..<16 { bytes.append(UInt8(r.read(UInt8.self) ?? 0)) }
                img.uuid = bytes.map { String(format: "%02X", $0) }.joined()
            case .idDylib, .loadDylib:
                _ = r.read(UInt32.self)  // name offset (relative to cmd)
                _ = r.read(UInt32.self)  // timestamp
                let cur = r.read(UInt32.self) ?? 0
                _ = r.read(UInt32.self)  // compat version
                // Name string sits at cmdStart + nameOffset; re-read simply.
                let nameStr = readDylibName(data, cmdStart: cmdStart, sliceOffset: sliceOffset)
                let ver = String(format: "%d.%d.%d", (cur >> 16) & 0xffff, (cur >> 8) & 0xff, cur & 0xff)
                if LoadCommand(rawValue: cmd) == .loadDylib {
                    img.dependencies.append(Dependency(name: nameStr, current: ver))
                }
            default:
                break
            }
            r.offset = cmdStart + Int(cmdSize)
        }

        if nsyms > 0 {
            img.symbols = Symbol.parseTable(data: data,
                                            sliceOffset: sliceOffset,
                                            symoff: Int(symtabOff),
                                            nsyms: Int(nsyms),
                                            stroff: Int(stroff),
                                            strsize: Int(strsize),
                                            is64: img.is64)
        }
        return img
    }

    private static func readDylibName(_ data: Data, cmdStart: Int, sliceOffset: Int) -> String {
        // dylib_command: cmd(4) cmdsize(4) name.offset(4) ...
        let nameOff = ByteReader(data).peek(UInt32.self, at: cmdStart + 8) ?? 0
        return cString(in: data, at: cmdStart + Int(nameOff))
    }
}

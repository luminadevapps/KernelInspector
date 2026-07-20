import Foundation

struct Symbol: Identifiable {
    let id = UUID()
    let name: String
    let value: UInt64
    let type: UInt8
    let sect: UInt8

    // n_type masks
    static let N_STAB: UInt8 = 0xe0
    static let N_TYPE: UInt8 = 0x0e
    static let N_EXT:  UInt8 = 0x01
    static let N_SECT: UInt8 = 0x0e   // symbol defined in section n_sect
    static let N_UNDF: UInt8 = 0x00

    var isExternal: Bool { (type & Symbol.N_EXT) != 0 }
    var isDebug: Bool { (type & Symbol.N_STAB) != 0 }
    var isDefined: Bool { (type & Symbol.N_TYPE) == Symbol.N_SECT }

    var kind: String {
        if isDebug { return "debug" }
        switch type & Symbol.N_TYPE {
        case Symbol.N_UNDF: return "undefined"
        case Symbol.N_SECT: return isExternal ? "global" : "local"
        default: return "abs"
        }
    }

    /// Parse the classic symbol table (LC_SYMTAB) of nlist_64 entries.
    static func parseTable(data: Data, sliceOffset: Int, symoff: Int, nsyms: Int,
                           stroff: Int, strsize: Int, is64: Bool) -> [Symbol] {
        var out: [Symbol] = []
        let entrySize = is64 ? 16 : 12
        let strBase = sliceOffset + stroff
        var r = ByteReader(data, offset: sliceOffset + symoff)
        for _ in 0..<nsyms {
            guard r.offset + entrySize <= data.count else { break }
            let n_strx = r.read(UInt32.self) ?? 0
            let n_type = UInt8(r.read(UInt8.self) ?? 0)
            let n_sect = UInt8(r.read(UInt8.self) ?? 0)
            _ = r.read(UInt16.self) // n_desc
            let n_value: UInt64 = is64 ? (r.read(UInt64.self) ?? 0) : UInt64(r.read(UInt32.self) ?? 0)
            let name = cString(in: data, at: strBase + Int(n_strx))
            if name.isEmpty { continue }
            out.append(Symbol(name: name, value: n_value, type: n_type, sect: n_sect))
        }
        return out
    }
}

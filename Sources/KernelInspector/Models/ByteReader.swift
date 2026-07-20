import Foundation

/// Little helper for reading little/big-endian integers out of a `Data` blob.
struct ByteReader {
    let data: Data
    var offset: Int
    var bigEndian: Bool

    init(_ data: Data, offset: Int = 0, bigEndian: Bool = false) {
        self.data = data
        self.offset = offset
        self.bigEndian = bigEndian
    }

    var remaining: Int { data.count - offset }

    mutating func read<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.count else { return nil }
        var value: T = 0
        for i in 0..<size {
            let byte = T(data[data.startIndex + offset + i])
            if bigEndian {
                value = (value << 8) | byte
            } else {
                value |= byte << (8 * i)
            }
        }
        offset += size
        return value
    }

    /// Peek an integer at an absolute offset without moving the cursor.
    func peek<T: FixedWidthInteger>(_ type: T.Type, at abs: Int) -> T? {
        var r = ByteReader(data, offset: abs, bigEndian: bigEndian)
        return r.read(type)
    }

    mutating func readCString(maxLength: Int) -> String {
        var bytes: [UInt8] = []
        for _ in 0..<maxLength {
            guard offset < data.count else { break }
            let b = data[data.startIndex + offset]
            offset += 1
            if b == 0 { break }
            bytes.append(b)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Read a fixed 16-byte name field (Mach-O sections/segments) as a string.
    mutating func readFixedString(_ length: Int) -> String {
        var bytes: [UInt8] = []
        for _ in 0..<length {
            guard offset < data.count else { break }
            bytes.append(data[data.startIndex + offset])
            offset += 1
        }
        while bytes.last == 0 { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Read a NUL-terminated string from a string table at a given index.
func cString(in data: Data, at index: Int) -> String {
    guard index >= 0, index < data.count else { return "" }
    var end = index
    while end < data.count && data[data.startIndex + end] != 0 { end += 1 }
    return String(decoding: data[(data.startIndex + index)..<(data.startIndex + end)], as: UTF8.self)
}

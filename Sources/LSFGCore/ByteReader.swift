import Foundation

/// Bounds-checked little-endian reads over a byte buffer.
public enum ParseError: Error, CustomStringConvertible {
    case outOfBounds(offset: Int, count: Int)
    case badMagic(String)
    case malformed(String)

    public var description: String {
        switch self {
        case let .outOfBounds(offset, count): "read of \(count) bytes at 0x\(String(offset, radix: 16)) is out of bounds"
        case let .badMagic(what): "bad magic: \(what)"
        case let .malformed(what): "malformed: \(what)"
        }
    }
}

struct ByteReader {
    let data: Data

    init(_ data: Data) { self.data = data }

    func check(_ offset: Int, _ count: Int) throws {
        guard offset >= 0, count >= 0, offset + count <= data.count else {
            throw ParseError.outOfBounds(offset: offset, count: count)
        }
    }

    func u8(_ offset: Int) throws -> UInt8 {
        try check(offset, 1)
        return data[data.startIndex + offset]
    }

    func u16(_ offset: Int) throws -> UInt16 {
        try check(offset, 2)
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }.littleEndian
    }

    func u32(_ offset: Int) throws -> UInt32 {
        try check(offset, 4)
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian
    }

    func int(_ offset: Int) throws -> Int { Int(try u32(offset)) }

    func bytes(_ offset: Int, _ count: Int) throws -> Data {
        try check(offset, count)
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
    }

    func fourCC(_ offset: Int) throws -> String {
        String(decoding: try bytes(offset, 4), as: UTF8.self)
    }

    /// NUL-terminated ASCII string.
    func cString(_ offset: Int) throws -> String {
        try check(offset, 1)
        var end = offset
        while end < data.count, data[data.startIndex + end] != 0 { end += 1 }
        return String(decoding: try bytes(offset, end - offset), as: UTF8.self)
    }
}

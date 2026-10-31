import Foundation

/// One leaf of a PE resource directory (type / name / language).
public struct PEResource: Sendable {
    public enum Key: Sendable, Hashable, CustomStringConvertible {
        case id(UInt32)
        case name(String)
        public var description: String {
            switch self {
            case let .id(v): String(v)
            case let .name(s): s
            }
        }
    }

    public let type: Key
    public let name: Key
    public let language: Key
    public let data: Data
}

/// Minimal PE32/PE32+ reader: resources, imports and machine type.
public enum PEFile {
    public static let rtRCData: UInt32 = 10

    /// What a Windows executable is built for and which DLLs it imports.
    public struct Info: Sendable {
        public let is64Bit: Bool
        /// Imported DLL names, lowercased (e.g. "dinput8.dll").
        public let imports: [String]
    }

    /// Parsed headers shared by the readers below.
    private struct Header {
        struct Section { let va: Int, virtualSize: Int, raw: Int, rawSize: Int }
        let reader: ByteReader
        let machine: UInt16
        let dataDirs: Int
        let sections: [Section]

        init(_ file: Data) throws {
            let r = ByteReader(file)
            guard try r.u16(0) == 0x5A4D else { throw ParseError.badMagic("MZ") }
            let pe = try r.int(0x3C)
            guard try r.u32(pe) == 0x0000_4550 else { throw ParseError.badMagic("PE") }
            let sectionCount = Int(try r.u16(pe + 6))
            let optionalSize = Int(try r.u16(pe + 20))
            let optional = pe + 24
            let isPE32Plus = try r.u16(optional) == 0x20B
            let sectionTable = optional + optionalSize
            reader = r
            machine = try r.u16(pe + 4)
            dataDirs = optional + (isPE32Plus ? 112 : 96)
            sections = try (0..<sectionCount).map { i in
                let s = sectionTable + 40 * i
                return Section(va: try r.int(s + 12), virtualSize: try r.int(s + 8),
                               raw: try r.int(s + 20), rawSize: try r.int(s + 16))
            }
        }

        func directoryRVA(_ index: Int) throws -> Int { try reader.int(dataDirs + 8 * index) }

        func fileOffset(rva: Int) throws -> Int {
            guard let s = sections.first(where: { rva >= $0.va && rva < $0.va + max($0.virtualSize, $0.rawSize) }) else {
                throw ParseError.malformed("RVA 0x\(String(rva, radix: 16)) not in any section")
            }
            return rva - s.va + s.raw
        }
    }

    public static func info(of file: Data) throws -> Info {
        let h = try Header(file)
        let r = h.reader
        var imports: [String] = []
        let importRVA = try h.directoryRVA(1)
        if importRVA != 0 {
            var d = try h.fileOffset(rva: importRVA)
            // IMAGE_IMPORT_DESCRIPTOR (20 bytes), terminated by an all-zero entry; Name is at +12.
            while imports.count < 4096 {
                let nameRVA = try r.int(d + 12)
                if nameRVA == 0 { break }
                imports.append(try r.cString(try h.fileOffset(rva: nameRVA)).lowercased())
                d += 20
            }
        }
        return Info(is64Bit: h.machine == 0x8664 || h.machine == 0xAA64, imports: imports)
    }

    public static func resources(in file: Data) throws -> [PEResource] {
        let h = try Header(file)
        let r = h.reader
        let resourceRVA = try h.directoryRVA(2)
        guard resourceRVA != 0 else { return [] }
        let base = try h.fileOffset(rva: resourceRVA)

        func key(_ raw: UInt32) throws -> PEResource.Key {
            guard raw & 0x8000_0000 != 0 else { return .id(raw) }
            let off = base + Int(raw & 0x7FFF_FFFF)
            let length = Int(try r.u16(off))
            let units = try (0..<length).map { try r.u16(off + 2 + 2 * $0) }
            return .name(String(decoding: units, as: UTF16.self))
        }

        func entries(_ dirOffset: Int) throws -> [(PEResource.Key, UInt32)] {
            let d = base + dirOffset
            let count = Int(try r.u16(d + 12)) + Int(try r.u16(d + 14))
            return try (0..<count).map { i in
                (try key(try r.u32(d + 16 + 8 * i)), try r.u32(d + 20 + 8 * i))
            }
        }

        var out: [PEResource] = []
        for (type, typeChild) in try entries(0) where typeChild & 0x8000_0000 != 0 {
            for (name, nameChild) in try entries(Int(typeChild & 0x7FFF_FFFF)) where nameChild & 0x8000_0000 != 0 {
                for (lang, leaf) in try entries(Int(nameChild & 0x7FFF_FFFF)) where leaf & 0x8000_0000 == 0 {
                    let entry = base + Int(leaf)
                    let rva = try r.int(entry)
                    let size = try r.int(entry + 4)
                    out.append(PEResource(type: type, name: name, language: lang,
                                          data: try r.bytes(try h.fileOffset(rva: rva), size)))
                }
            }
        }
        return out
    }
}

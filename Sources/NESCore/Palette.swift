import Foundation

/// Errors thrown while loading a `.pal` file.
public enum PALLoadError: Error, CustomStringConvertible {
    /// The file held fewer than `bytesNeeded` bytes.
    case tooShort(byteCount: Int)

    public var description: String {
        switch self {
        case .tooShort(let byteCount):
            return "palette is \(byteCount) bytes; need at least 192"
        }
    }
}

/// The fixed 64-entry palette of the NES PPU (2C02) as packed RGBA values.
public enum Palette {

    /// The built-in 64 colors from 2C02G_wiki.pal. Each entry is 0xRRGGBB.
    public static let defaultRGB: [UInt32] = [
        0x626262, 0x001C95, 0x1904AC, 0x42009D, 0x61006B, 0x6E0025, 0x650500, 0x491E00,
        0x223700, 0x004900, 0x004F00, 0x004816, 0x00355E, 0x000000, 0x000000, 0x000000,
        0xABABAB, 0x0C4EDB, 0x3D2EFF, 0x7115F3, 0x9B0BB9, 0xB01262, 0xA92704, 0x894600,
        0x576600, 0x237F00, 0x008900, 0x008332, 0x006D90, 0x000000, 0x000000, 0x000000,
        0xFFFFFF, 0x57A5FF, 0x8287FF, 0xB46DFF, 0xDF60FF, 0xF863C6, 0xF8746D, 0xDE9020,
        0xB3AE00, 0x81C800, 0x56D522, 0x3DD36F, 0x3EC1C8, 0x4E4E4E, 0x000000, 0x000000,
        0xFFFFFF, 0xBEE0FF, 0xCDD4FF, 0xE0CAFF, 0xF1C4FF, 0xFCC4EF, 0xFDCACE, 0xF5D4AF,
        0xE6DF9C, 0xD3E99A, 0xC2EFA8, 0xB7EFC4, 0xB6EAE5, 0xB8B8B8, 0x000000, 0x000000,
    ]

    /// The active 64 colors, packed as 0xRRGGBB.
    public nonisolated(unsafe) static private(set) var rgb: [UInt32] = defaultRGB

    /// Packed RGBA (0xAABBGGRR) for the renderer, derived from `rgb`.
    public nonisolated(unsafe) static private(set) var rgba: [UInt32] = pack(defaultRGB)

    /// Packs 0xRRGGBB colors into the renderer's 0xAABBGGRR layout.
    private static func pack(_ colors: [UInt32]) -> [UInt32] {
        colors.map { c in
            let r = (c >> 16) & 0xFF
            let g = (c >> 8) & 0xFF
            let b = c & 0xFF

            return (0xFF << 24) | (b << 16) | (g << 8) | r
        }
    }

    /// Replaces the active palette with the colors from a `.pal` file.
    public static func load(from url: URL) throws {
        load(rgb: try loadRGB(from: url))
    }

    /// Replaces the active palette with raw `.pal` bytes.
    public static func load(from data: Data) throws {
        load(rgb: try loadRGB(from: data))
    }

    /// Replaces the active palette with an already-parsed color array.
    public static func load(rgb colors: [UInt32]) {
        rgb = colors
        rgba = pack(colors)
    }

    /// The number of color entries in an NES palette.
    private static let entryCount = 64

    /// The number of bytes needed for the no-emphasis palette (64 RGB triples).
    private static let bytesNeeded = 64 * 3  // 192

    /// Loads a `.pal` file as 64 colors packed as 0xRRGGBB.
    private static func loadRGB(from url: URL) throws -> [UInt32] {
        try loadRGB(from: Data(contentsOf: url))
    }

    /// Parses raw `.pal` bytes into 64 colors packed as 0xRRGGBB.
    private static func loadRGB(from data: Data) throws -> [UInt32] {
        guard data.count >= bytesNeeded else {
            throw PALLoadError.tooShort(byteCount: data.count)
        }

        let bytes = [UInt8](data.prefix(bytesNeeded))
        return (0..<entryCount).map { i in
            let r = UInt32(bytes[i * 3])
            let g = UInt32(bytes[i * 3 + 1])
            let b = UInt32(bytes[i * 3 + 2])
            return (r << 16) | (g << 8) | b
        }
    }
}

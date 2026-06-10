import Foundation

public enum CartridgeError: Error, CustomStringConvertible {
  case badMagic
  case unsupportedMapper(Int)
  case truncated

  public var description: String {
    switch self {
    case .badMagic:
      return "Not a iNES file (missing 'NES\\x1a' magic)."
    case .unsupportedMapper(let m):
      return "Unsupported mapper \(m). Only NROM (0) is implemented."
    case .truncated:
      return "ROM file is shorter than its header claims."
    }
  }
}

/// An iNES cartridge using the NROM (mapper 0) layout.
///
/// CPU view: $8000-$FFFF maps to the 32KB PRG-ROM.
/// PPU view: $0000-$1FFF maps to the 8KB CHR-ROM pattern tables.
public final class Cartridge {
  private let prg: [UInt8]  // 32KB PRG-ROM
  private var chr: [UInt8]  // 8KB CHR-ROM pattern tables.

  public init(data: [UInt8]) throws {
    guard data.count >= 16, data[0] == 0x4E, data[1] == 0x45, data[2] == 0x53, data[3] == 0x1A
    else { throw CartridgeError.badMagic }

    let prgUnits = Int(data[4])
    let flags6 = data[6]
    let flags7 = data[7]

    let mapper = (Int(flags7) & 0xF0) | (Int(flags6) >> 4)
    guard mapper == 0
    else { throw CartridgeError.unsupportedMapper(mapper) }

    // A trainer (512 bytes) sits between the header and PRG when flag6 bit2 is set.
    var offset = 16
    if flags6 & 0x04 != 0 { offset += 512 }

    let prgSize = prgUnits * 0x4000
    guard data.count >= offset + prgSize
    else { throw CartridgeError.truncated }

    prg = Array(data[offset..<offset + prgSize])
    offset += prgSize

    guard data.count >= offset + 0x2000
    else { throw CartridgeError.truncated }

    chr = Array(data[offset..<offset + 0x2000])
  }

  /// Read from program ROM (starts at $8000)
  public func prgRead(_ addr: UInt16) -> UInt8 {
    guard addr >= 0x8000 else { return 0 }
    return prg[Int(addr - 0x8000)]
  }

  /// Read from Character ROM (fixed to $0000-$1FFF range)
  public func chrRead(_ addr: UInt16) -> UInt8 {
    return chr[Int(addr) & 0x1FFF]
  }
}

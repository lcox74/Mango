import Testing

@testable import NESCore

/// Build a minimal 16KB-PRG + 8KB-CHR NROM image whose reset vector
/// points at $8000.
private func makeCartridge(program: [UInt8]) throws -> Cartridge {
  var rom: [UInt8] = [
    0x4E, 0x45, 0x53, 0x1A,  // Magic "NES"
    0x02,  // Size of PRG ROM  2*16 KB = 32 KB
    0x01,  // Size of CHR ROM 1*8 KB = 8KB
    0x00,  // Mapper 0
    0x00,  //
    0, 0, 0, 0, 0, 0, 0, 0,
  ]  // iNES header: 32KB PRG, 8KB CHR

  var prg = [UInt8](repeating: 0, count: 0x8000)
  for (i, byte) in program.enumerated() {
    prg[i] = byte
  }

  prg[0x7FFC] = 0x00  // reset vector low  ($8000)
  prg[0x7FFD] = 0x80  // reset vector high

  rom += prg
  rom += [UInt8](repeating: 0, count: 0x2000)  // CHR

  return try Cartridge(data: rom)
}

@Test func cartridgeHeaderParsing() throws {
  let cart = try makeCartridge(program: [])

  #expect(cart.prgRead(0xFFFC) == 0x00)
  #expect(cart.prgRead(0xFFFD) == 0x80)
}

@Test func addWithCarryAndStore() throws {
  let cart = try makeCartridge(
    program: [
      0xA9, 0x05,  // LDA #$05
      0x69, 0x03,  // ADC #$03
      0x85, 0x10,  // STA $10
    ],
  )

  let nes = Console(cartridge: cart)
  #expect(nes.cpu.pc == 0x8000)

  _ = nes.cpu.step()  // LDA
  _ = nes.cpu.step()  // ADC
  #expect(nes.cpu.a == 0x08)

  _ = nes.cpu.step()  // STA
  #expect(nes.read(0x0010) == 0x08)
}

@Test func branchLoop() throws {
  let cart = try makeCartridge(
    program: [
      0xA2, 0x00,  // LDX #$00
      0xE8,  // INX
      0xE0, 0x03,  // CPX #$03
      0xD0, 0xFB,  // BNE -4 (loop untile X == 3)
    ],
  )

  let nes = Console(cartridge: cart)
  for _ in 0..<20 {
    _ = nes.cpu.step()
  }

  #expect(nes.cpu.x == 0x03)
}

/// A program that keeps writing to RAM and ticking the PPU so a snapshot has to
/// capture moving state, not just static registers.
private func makeBusyCartridge() throws -> Cartridge {
  try makeCartridge(
    program: [
      0xA2, 0x00,  // LDX #$00
      0xE8,  // INX
      0x8A,  // TXA
      0x95, 0x00,  // STA $00,X
      0x8D, 0x00, 0x20,  // STA $2000 (PPUCTRL)
      0x4C, 0x02, 0x80,  // JMP $8002 (back to INX)
    ],
  )
}

@Test func snapshotRestoreRoundTrips() throws {
  // The profiler relies on snapshot/restore being a "complete" copy: rewinding
  // and replaying the same steps must land in the exact same place.
  let nes = Console(cartridge: try makeBusyCartridge())

  for _ in 0..<30 {
    _ = nes.cpu.step()
  }

  let snap = nes.snapshot()

  /// Step a fixed amount and fingerprint everything observable.
  func replay() -> (UInt8, UInt8, UInt16, UInt16, UInt32) {
    for _ in 0..<200 {
      _ = nes.cpu.step()
    }

    let fb = nes.framebufferSnapshot().reduce(UInt32(0)) { $0 &* 31 &+ $1 }
    var ram: UInt16 = 0

    for a in 0..<UInt16(0x20) {
      ram = ram &* 31 &+ UInt16(nes.read(a))
    }

    return (nes.cpu.a, nes.cpu.x, nes.cpu.pc, ram, fb)
  }

  let first = replay()
  nes.restore(snap)
  let second = replay()

  #expect(first == second)
}

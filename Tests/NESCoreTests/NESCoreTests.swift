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

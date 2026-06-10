import Foundation

/// A 16-bit address space that transfers 8-bit data.
public protocol MemoryBus: AnyObject {
  func read(_ addr: UInt16) -> UInt8
  func write(_ addr: UInt16, _ value: UInt8)
}

/// NES 6502 CPU following the Ricoh 2A03, this also has binary-coded decimal
/// disabled. The `step()` call executes one instruction and returns the cycles
/// it took.
public final class CPU {
  // Registers
  public var a: UInt8 = 0
  public var x: UInt8 = 0
  public var y: UInt8 = 0
  public var sp: UInt8 = 0xFD
  public var pc: UInt16 = 0

  // Status flags (the D flag is tracked but ignored by ADC/SBC, as on the 2A03).
  private var cFlag = false
  private var zFlag = false
  private var iFlag = true
  private var dFlag = false
  private var vFlag = false
  private var nFlag = false

  private unowned let bus: MemoryBus
  private var pageCrossed = false

  public init(bus: MemoryBus) {
    self.bus = bus
  }

  // Bus Shortcuts, I think they will inline.

  private func read(_ a: UInt16) -> UInt8 { bus.read(a) }
  private func write(_ a: UInt16, _ v: UInt8) { bus.write(a, v) }

  private func read16(_ a: UInt16) -> UInt16 {
    UInt16(read(a)) | (UInt16(read(a &+ 1)) << 8)
  }

  /// 6502 indirect-pointer read that reproduces the page-boundary wrap bug.
  private func read16Bug(_ a: UInt16) -> UInt16 {
    let lo = read(a)
    let hiAddr = (a & 0xFF00) | UInt16((a &+ 1) & 0x00FF)
    let hi = read(hiAddr)
    return UInt16(lo) | (UInt16(hi) << 8)
  }

  // Stack Shortcuts.

  private func push(_ v: UInt8) {
    write(0x0100 | UInt16(sp), v)
    sp = sp &- 1
  }

  private func pull() -> UInt8 {
    sp = sp &+ 1
    return read(0x0100 | UInt16(sp))
  }

  private func push16(_ v: UInt16) {
    push(UInt8(v >> 8))
    push(UInt8(v & 0xFF))
  }

  private func pull16() -> UInt16 {
    let lo = UInt16(pull())
    let hi = UInt16(pull())

    return lo | (hi << 8)
  }

  // Status Byte Shortcuts

  private func statusByte(brk: Bool) -> UInt8 {
    var p: UInt8 = 0x20

    // Build the status
    if cFlag { p |= 0x01 }
    if zFlag { p |= 0x02 }
    if iFlag { p |= 0x04 }
    if dFlag { p |= 0x08 }
    if brk { p |= 0x10 }
    if vFlag { p |= 0x40 }
    if nFlag { p |= 0x80 }

    return p
  }

  private func setStatus(_ p: UInt8) {
    cFlag = p & 0x01 != 0
    zFlag = p & 0x02 != 0
    iFlag = p & 0x04 != 0
    dFlag = p & 0x08 != 0
    vFlag = p & 0x40 != 0
    nFlag = p & 0x80 != 0
  }

  private func setZN(_ v: UInt8) {
    zFlag = v == 0
    nFlag = v & 0x80 != 0
  }

  // Interrupts

  public func reset() {
    pc = read16(0xFFFC)
    sp = 0xFD

    setStatus(0x24)
    a = 0
    x = 0
    y = 0
  }

  /// Non-maskable interrupt (delivered by the PPU at vblank).
  public func nmi() -> Int {
    push16(pc)
    push(statusByte(brk: false))

    iFlag = true
    pc = read16(0xFFFA)

    return 7
  }

  // Addressing Modes

  private func imm() -> UInt16 {
    let a = pc
    pc = pc &+ 1

    return a
  }

  private func zp() -> UInt16 {
    let a = UInt16(read(pc))
    pc = pc &+ 1

    return a
  }

  private func zpx() -> UInt16 {
    let a = UInt16(read(pc) &+ x)
    pc = pc &+ 1

    return a
  }

  private func zpy() -> UInt16 {
    let a = UInt16(read(pc) &+ y)
    pc = pc &+ 1

    return a
  }

  private func absA() -> UInt16 {
    let a = read16(pc)
    pc = pc &+ 2

    return a
  }

  private func abx() -> UInt16 {
    let base = read16(pc)
    pc = pc &+ 2

    let a = base &+ UInt16(x)
    pageCrossed = (base & 0xFF00) != (a & 0xFF00)

    return a
  }

  private func aby() -> UInt16 {
    let base = read16(pc)
    pc = pc &+ 2

    let a = base &+ UInt16(y)
    pageCrossed = (base & 0xFF00) != (a & 0xFF00)

    return a
  }

  private func izx() -> UInt16 {
    let p = read(pc) &+ x
    pc = pc &+ 1

    let lo = read(UInt16(p))
    let hi = read(UInt16(p &+ 1))

    return UInt16(lo) | (UInt16(hi) << 8)
  }

  private func izy() -> UInt16 {
    let p = read(pc)
    pc = pc &+ 1

    let lo = read(UInt16(p))
    let hi = read(UInt16(p &+ 1))
    let base = UInt16(lo) | (UInt16(hi) << 8)
    let a = base &+ UInt16(y)

    pageCrossed = (base & 0xFF00) != (a & 0xFF00)
    return a
  }

  // Operation Helpers

  private func adc(_ value: UInt8) {
    let sum = Int(a) + Int(value) + (cFlag ? 1 : 0)
    let result = UInt8(sum & 0xFF)

    cFlag = sum > 0xFF
    vFlag = (~(a ^ value) & (a ^ result) & 0x80) != 0

    a = result
    setZN(a)
  }

  private func compare(_ reg: UInt8, _ value: UInt8) {
    cFlag = reg >= value
    setZN(reg &- value)
  }

  private func aslVal(_ v: UInt8) -> UInt8 {
    cFlag = v & 0x80 != 0

    let r = v << 1
    setZN(r)

    return r
  }
  private func lsrVal(_ v: UInt8) -> UInt8 {
    cFlag = v & 0x01 != 0

    let r = v >> 1
    setZN(r)

    return r
  }
  private func rolVal(_ v: UInt8) -> UInt8 {
    let nc = v & 0x80 != 0
    let r = (v << 1) | (cFlag ? 1 : 0)

    cFlag = nc
    setZN(r)

    return r
  }
  private func rorVal(_ v: UInt8) -> UInt8 {
    let nc = v & 0x01 != 0
    let r = (v >> 1) | (cFlag ? 0x80 : 0)

    cFlag = nc
    setZN(r)

    return r
  }

  private func branch(_ condition: Bool) -> Int {
    let off = UInt16(bitPattern: Int16(Int8(bitPattern: read(pc))))
    pc = pc &+ 1

    guard condition else { return 0 }

    let target = pc &+ off
    var extra = 1

    if (target & 0xFF00) != (pc & 0xFF00) {
      extra += 1
    }

    pc = target

    return extra
  }

  // Execute a single instruction. Taken from the 6502 spec and ignores swift
  // formatting as spreading this out makes it completely unreadable.
  // swift-format-ignore
  public func step() -> Int {
    pageCrossed = false
    let opcode = read(pc)
    pc = pc &+ 1

    switch opcode {

    // ADC
    case 0x69: adc(read(imm())); return 2
    case 0x65: adc(read(zp())); return 3
    case 0x75: adc(read(zpx())); return 4
    case 0x6D: adc(read(absA())); return 4
    case 0x7D: adc(read(abx())); return pageCrossed ? 5 : 4
    case 0x79: adc(read(aby())); return pageCrossed ? 5 : 4
    case 0x61: adc(read(izx())); return 6
    case 0x71: adc(read(izy())); return pageCrossed ? 6 : 5

    // AND
    case 0x29: a &= read(imm()); setZN(a); return 2
    case 0x25: a &= read(zp()); setZN(a); return 3
    case 0x35: a &= read(zpx()); setZN(a); return 4
    case 0x2D: a &= read(absA()); setZN(a); return 4
    case 0x3D: a &= read(abx()); setZN(a); return pageCrossed ? 5 : 4
    case 0x39: a &= read(aby()); setZN(a); return pageCrossed ? 5 : 4
    case 0x21: a &= read(izx()); setZN(a); return 6
    case 0x31: a &= read(izy()); setZN(a); return pageCrossed ? 6 : 5

    // ASL
    case 0x0A: a = aslVal(a); return 2
    case 0x06: let m = zp(); write(m, aslVal(read(m))); return 5
    case 0x16: let m = zpx(); write(m, aslVal(read(m))); return 6
    case 0x0E: let m = absA(); write(m, aslVal(read(m))); return 6
    case 0x1E: let m = abx(); write(m, aslVal(read(m))); return 7

    // Branches
    case 0x90: return 2 + branch(!cFlag)   // BCC
    case 0xB0: return 2 + branch(cFlag)    // BCS
    case 0xF0: return 2 + branch(zFlag)    // BEQ
    case 0xD0: return 2 + branch(!zFlag)   // BNE
    case 0x30: return 2 + branch(nFlag)    // BMI
    case 0x10: return 2 + branch(!nFlag)   // BPL
    case 0x50: return 2 + branch(!vFlag)   // BVC
    case 0x70: return 2 + branch(vFlag)    // BVS

    // BIT
    case 0x24:
      let v = read(zp())

      zFlag = (a & v) == 0
      vFlag = v & 0x40 != 0
      nFlag = v & 0x80 != 0

      return 3

    case 0x2C:
      let v = read(absA());

      zFlag = (a & v) == 0
      vFlag = v & 0x40 != 0
      nFlag = v & 0x80 != 0

      return 4

    // BRK
    case 0x00:
      pc = pc &+ 1
      push16(pc)
      push(statusByte(brk: true))

      iFlag = true
      pc = read16(0xFFFE)

      return 7

    // Flag ops
    case 0x18: cFlag = false; return 2   // CLC
    case 0x38: cFlag = true; return 2    // SEC
    case 0x58: iFlag = false; return 2   // CLI
    case 0x78: iFlag = true; return 2    // SEI
    case 0xD8: dFlag = false; return 2   // CLD
    case 0xF8: dFlag = true; return 2    // SED
    case 0xB8: vFlag = false; return 2   // CLV

    // CMP
    case 0xC9: compare(a, read(imm())); return 2
    case 0xC5: compare(a, read(zp())); return 3
    case 0xD5: compare(a, read(zpx())); return 4
    case 0xCD: compare(a, read(absA())); return 4
    case 0xDD: compare(a, read(abx())); return pageCrossed ? 5 : 4
    case 0xD9: compare(a, read(aby())); return pageCrossed ? 5 : 4
    case 0xC1: compare(a, read(izx())); return 6
    case 0xD1: compare(a, read(izy())); return pageCrossed ? 6 : 5

    // CPX
    case 0xE0: compare(x, read(imm())); return 2
    case 0xE4: compare(x, read(zp())); return 3
    case 0xEC: compare(x, read(absA())); return 4

    // CPY
    case 0xC0: compare(y, read(imm())); return 2
    case 0xC4: compare(y, read(zp())); return 3
    case 0xCC: compare(y, read(absA())); return 4

    // DEC
    case 0xC6: let m = zp(); let r = read(m) &- 1; write(m, r); setZN(r); return 5
    case 0xD6: let m = zpx(); let r = read(m) &- 1; write(m, r); setZN(r); return 6
    case 0xCE: let m = absA(); let r = read(m) &- 1; write(m, r); setZN(r); return 6
    case 0xDE: let m = abx(); let r = read(m) &- 1; write(m, r); setZN(r); return 7
    case 0xCA: x = x &- 1; setZN(x); return 2   // DEX
    case 0x88: y = y &- 1; setZN(y); return 2   // DEY

    // EOR
    case 0x49: a ^= read(imm()); setZN(a); return 2
    case 0x45: a ^= read(zp()); setZN(a); return 3
    case 0x55: a ^= read(zpx()); setZN(a); return 4
    case 0x4D: a ^= read(absA()); setZN(a); return 4
    case 0x5D: a ^= read(abx()); setZN(a); return pageCrossed ? 5 : 4
    case 0x59: a ^= read(aby()); setZN(a); return pageCrossed ? 5 : 4
    case 0x41: a ^= read(izx()); setZN(a); return 6
    case 0x51: a ^= read(izy()); setZN(a); return pageCrossed ? 6 : 5

    // INC
    case 0xE6: let m = zp(); let r = read(m) &+ 1; write(m, r); setZN(r); return 5
    case 0xF6: let m = zpx(); let r = read(m) &+ 1; write(m, r); setZN(r); return 6
    case 0xEE: let m = absA(); let r = read(m) &+ 1; write(m, r); setZN(r); return 6
    case 0xFE: let m = abx(); let r = read(m) &+ 1; write(m, r); setZN(r); return 7
    case 0xE8: x = x &+ 1; setZN(x); return 2   // INX
    case 0xC8: y = y &+ 1; setZN(y); return 2   // INY

    // JMP
    case 0x4C: pc = read16(pc); return 3
    case 0x6C: pc = read16Bug(read16(pc)); return 5

    // JSR
    case 0x20:
      let target = read16(pc)
      push16(pc &+ 1)   // address of the operand's high byte; RTS adds 1
      pc = target
      return 6

    // LDA
    case 0xA9: a = read(imm()); setZN(a); return 2
    case 0xA5: a = read(zp()); setZN(a); return 3
    case 0xB5: a = read(zpx()); setZN(a); return 4
    case 0xAD: a = read(absA()); setZN(a); return 4
    case 0xBD: a = read(abx()); setZN(a); return pageCrossed ? 5 : 4
    case 0xB9: a = read(aby()); setZN(a); return pageCrossed ? 5 : 4
    case 0xA1: a = read(izx()); setZN(a); return 6
    case 0xB1: a = read(izy()); setZN(a); return pageCrossed ? 6 : 5

    // LDX
    case 0xA2: x = read(imm()); setZN(x); return 2
    case 0xA6: x = read(zp()); setZN(x); return 3
    case 0xB6: x = read(zpy()); setZN(x); return 4
    case 0xAE: x = read(absA()); setZN(x); return 4
    case 0xBE: x = read(aby()); setZN(x); return pageCrossed ? 5 : 4

    // LDY
    case 0xA0: y = read(imm()); setZN(y); return 2
    case 0xA4: y = read(zp()); setZN(y); return 3
    case 0xB4: y = read(zpx()); setZN(y); return 4
    case 0xAC: y = read(absA()); setZN(y); return 4
    case 0xBC: y = read(abx()); setZN(y); return pageCrossed ? 5 : 4

    // LSR
    case 0x4A: a = lsrVal(a); return 2
    case 0x46: let m = zp(); write(m, lsrVal(read(m))); return 5
    case 0x56: let m = zpx(); write(m, lsrVal(read(m))); return 6
    case 0x4E: let m = absA(); write(m, lsrVal(read(m))); return 6
    case 0x5E: let m = abx(); write(m, lsrVal(read(m))); return 7

    // NOP
    case 0xEA: return 2

    // ORA
    case 0x09: a |= read(imm()); setZN(a); return 2
    case 0x05: a |= read(zp()); setZN(a); return 3
    case 0x15: a |= read(zpx()); setZN(a); return 4
    case 0x0D: a |= read(absA()); setZN(a); return 4
    case 0x1D: a |= read(abx()); setZN(a); return pageCrossed ? 5 : 4
    case 0x19: a |= read(aby()); setZN(a); return pageCrossed ? 5 : 4
    case 0x01: a |= read(izx()); setZN(a); return 6
    case 0x11: a |= read(izy()); setZN(a); return pageCrossed ? 6 : 5

    // Stack ops
    case 0x48: push(a); return 3                       // PHA
    case 0x08: push(statusByte(brk: true)); return 3   // PHP
    case 0x68: a = pull(); setZN(a); return 4          // PLA
    case 0x28: setStatus(pull()); return 4             // PLP

    // ROL
    case 0x2A: a = rolVal(a); return 2
    case 0x26: let m = zp(); write(m, rolVal(read(m))); return 5
    case 0x36: let m = zpx(); write(m, rolVal(read(m))); return 6
    case 0x2E: let m = absA(); write(m, rolVal(read(m))); return 6
    case 0x3E: let m = abx(); write(m, rolVal(read(m))); return 7

    // ROR
    case 0x6A: a = rorVal(a); return 2
    case 0x66: let m = zp(); write(m, rorVal(read(m))); return 5
    case 0x76: let m = zpx(); write(m, rorVal(read(m))); return 6
    case 0x6E: let m = absA(); write(m, rorVal(read(m))); return 6
    case 0x7E: let m = abx(); write(m, rorVal(read(m))); return 7

    // RTI / RTS
    case 0x40: setStatus(pull()); pc = pull16(); return 6
    case 0x60: pc = pull16() &+ 1; return 6

    // SBC
    case 0xE9: adc(read(imm()) ^ 0xFF); return 2
    case 0xE5: adc(read(zp()) ^ 0xFF); return 3
    case 0xF5: adc(read(zpx()) ^ 0xFF); return 4
    case 0xED: adc(read(absA()) ^ 0xFF); return 4
    case 0xFD: adc(read(abx()) ^ 0xFF); return pageCrossed ? 5 : 4
    case 0xF9: adc(read(aby()) ^ 0xFF); return pageCrossed ? 5 : 4
    case 0xE1: adc(read(izx()) ^ 0xFF); return 6
    case 0xF1: adc(read(izy()) ^ 0xFF); return pageCrossed ? 6 : 5

    // STA
    case 0x85: write(zp(), a); return 3
    case 0x95: write(zpx(), a); return 4
    case 0x8D: write(absA(), a); return 4
    case 0x9D: write(abx(), a); return 5
    case 0x99: write(aby(), a); return 5
    case 0x81: write(izx(), a); return 6
    case 0x91: write(izy(), a); return 6

    // STX
    case 0x86: write(zp(), x); return 3
    case 0x96: write(zpy(), x); return 4
    case 0x8E: write(absA(), x); return 4

    // STY
    case 0x84: write(zp(), y); return 3
    case 0x94: write(zpx(), y); return 4
    case 0x8C: write(absA(), y); return 4

    // Transfers
    case 0xAA: x = a; setZN(x); return 2   // TAX
    case 0xA8: y = a; setZN(y); return 2   // TAY
    case 0xBA: x = sp; setZN(x); return 2  // TSX
    case 0x8A: a = x; setZN(a); return 2   // TXA
    case 0x9A: sp = x; return 2            // TXS
    case 0x98: a = y; setZN(a); return 2   // TYA

    default:
      // Unimplemented as I couldn't be bothered and the game doesnt need
      // all of them.
      return 2
    }
  }

}

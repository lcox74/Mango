import Foundation

/// The console which owns all and is what is used to emulate
public final class Console: MemoryBus {

  public let cartridge: Cartridge
  public let ppu: PPU
  public private(set) var cpu: CPU!
  public let controller1 = Controller()
  public let controller2 = Controller()

  private var ram = [UInt8](repeating: 0, count: 0x800)  // 2KB internal RAM
  private var dmaStall = 0

  /// Debug number of NMIs serviced since power-on.
  public private(set) var nmiCount = 0

  public init(cartridge: Cartridge) {
    self.cartridge = cartridge
    self.ppu = PPU(cartridge: cartridge)
    self.cpu = CPU(bus: self)

    cpu.reset()
  }

  /// Copies the most recently rendered frame as packed RGBA.
  public func framebufferSnapshot() -> [UInt32] { ppu.framebufferSnapshot() }

  /// Borrows the live framebuffer without copying.
  public func withFramebuffer<R>(_ body: (UnsafePointer<UInt32>) -> R) -> R {
    ppu.withFramebuffer(body)
  }

  // Frame loop

  /// Run the console until the PPU completes one frame.
  public func stepFrame() {
    ppu.frameComplete = false
    while !ppu.frameComplete {
      clock()
    }
  }

  /// Execute one CPU instruction and the matching PPU dots.
  private func clock() {
    if ppu.nmiPending {
      ppu.nmiPending = false
      nmiCount += 1

      tickPPU(cpu.nmi() * 3)
    }

    let cycles = cpu.step() + dmaStall
    dmaStall = 0

    tickPPU(cycles * 3)
  }

  private func tickPPU(_ count: Int) {
    ppu.step(count)  // PPU loops internally
  }

  public func read(_ addr: UInt16) -> UInt8 {
    switch addr {
    case 0x0000...0x1FFF:
      return ram[Int(addr & 0x07FF)]

    case 0x2000...0x3FFF:
      return ppu.readRegister(addr & 0x0007)

    case 0x4016:
      return controller1.read()

    case 0x4017:
      return controller2.read()

    case 0x4000...0x401F:
      return 0  // Unimplemented IO like APU.

    default:
      return cartridge.prgRead(addr)
    }
  }

  public func write(_ addr: UInt16, _ data: UInt8) {
    switch addr {
    case 0x0000...0x1FFF:
      ram[Int(addr & 0x07FF)] = data

    case 0x2000...0x3FFF:
      ppu.writeRegister(addr & 0x0007, data)

    case 0x4014:
      oamDMA(page: data)

    case 0x4016:
      controller1.write(data)
      controller2.write(data)

    case 0x4000...0x401F:
      break  // APU not implemented

    default:
      break  // Cannot write to ROM
    }
  }

  /// $4014 OAM DMA: copy 256 bytes from CPU page into PPU OAM. This will
  // stall the CPU.
  private func oamDMA(page: UInt8) {
    let base = UInt16(page) << 8

    var i = 0
    while i < 256 {
      ppu.writeOAM(read(base + UInt16(i)))
      i += 1
    }

    dmaStall += 513
  }
}

import Foundation

/// NES Picture Processing unit following the 2C02. It will render one pixel
/// per `step()` call over a 341 x 262 grid (cycle x scanline).
public final class PPU {

  // Output: 256x240 packed RGBA, refreshed once per frame.
  private var fb: [UInt32]
  public static let frameWidth = 256
  public static let frameHeight = 240
  private static let frameCount = frameWidth * frameHeight

  /// Returns the current frame as an isolated copy, this triggers when the PPU
  /// mutates the buffer.
  public func framebufferSnapshot() -> [UInt32] { fb }

  /// Borrows a live framebuffer for the duration of `body` to be able to
  /// upload direclty to a Metal Texture buffer.
  public func withFramebuffer<R>(_ body: (UnsafePointer<UInt32>) -> R) -> R {
    fb.withUnsafeBufferPointer { body($0.baseAddress!) }
  }

  public var frameComplete = false  // Set true at the start of vblank
  public var nmiPending = false  // Raised when a NMI should be sent to CPU

  private let cart: Cartridge
  private let paletteRGBA = Palette.rgba  // index to packed RGBA mapping

  // Internal memory.
  private var vram = [UInt8](repeating: 0, count: 0x800)  // two nametables
  private var palette = [UInt8](repeating: 0, count: 0x20)  // palette RAM
  private var oam = [UInt8](repeating: 0, count: 0x100)  // 64 sprites x 4 bytes

  // Registers exposed to the CPU.
  private var ctrl: UInt8 = 0  // $2000
  private var mask: UInt8 = 0  // $2001
  private var status: UInt8 = 0  // $2002
  private var oamAddr: UInt8 = 0  // $2003

  // Loopy scroll registers.
  private var v: UInt16 = 0  // current VRAM address (15 bits)
  private var t: UInt16 = 0  // temporary VRAM address
  private var fineX: UInt8 = 0  // fine X scroll (3 bits)
  private var writeToggle = false  // $2005/$2006 first/second write latch (w)

  private var readBuffer: UInt8 = 0  // $2007 buffered read

  // Scan position.
  private var scanline = 261  // 0...239 visible, 240 post, 241...260 vblank, 261 pre-render
  private var cycle = 0  // 0...340

  // Background fetch latches and shift registers.
  private var ntByte: UInt8 = 0
  private var atByte: UInt8 = 0
  private var bgLoByte: UInt8 = 0
  private var bgHiByte: UInt8 = 0
  private var bgShiftLo: UInt16 = 0
  private var bgShiftHi: UInt16 = 0
  private var bgAttrShiftLo: UInt16 = 0
  private var bgAttrShiftHi: UInt16 = 0

  // Sprites prepared for the scanline currently being drawn (max 8).
  private var spriteCount = 0
  private var spriteX = [Int](repeating: 0, count: 8)
  private var spriteLo = [UInt8](repeating: 0, count: 8)
  private var spriteHi = [UInt8](repeating: 0, count: 8)
  private var spriteAttr = [UInt8](repeating: 0, count: 8)
  private var spriteIsZero = [Bool](repeating: false, count: 8)

  public init(cartridge: Cartridge) {
    self.cart = cartridge
    fb = [UInt32](repeating: 0xFF00_0000, count: Self.frameCount)
  }

  private var vramIncrement: UInt16 = 1
  private var spritePatternBase: UInt16 = 0
  private var bgPatternBase: UInt16 = 0
  private var spriteHeight: Int = 8
  private var nmiEnabled: Bool = false

  private var showBackground: Bool = false
  private var showSprites: Bool = false
  private var showBackgroundLeft: Bool = false
  private var showSpritesLeft: Bool = false
  private var renderingEnabled: Bool = false

  private func decodeCtrl() {
    vramIncrement = (ctrl & 0x04) != 0 ? 32 : 1
    spritePatternBase = (ctrl & 0x08) != 0 ? 0x1000 : 0
    bgPatternBase = (ctrl & 0x10) != 0 ? 0x1000 : 0
    spriteHeight = (ctrl & 0x20) != 0 ? 16 : 8
    nmiEnabled = (ctrl & 0x80) != 0
  }

  private func decodeMask() {
    showBackground = (mask & 0x08) != 0
    showSprites = (mask & 0x10) != 0
    showBackgroundLeft = (mask & 0x02) != 0
    showSpritesLeft = (mask & 0x04) != 0
    renderingEnabled = showBackground || showSprites
  }

  // CPU register interface ($2000-$2007)

  public func readRegister(_ addr: UInt16) -> UInt8 {
    switch addr & 7 {
    case 2:  // PPUSTATUS
      let result = (status & 0xE0) | (readBuffer & 0x1F)

      status &= ~0x80  // reading clears vblank
      writeToggle = false

      return result

    case 4:  // OAMDATA
      return oam[Int(oamAddr)]

    case 7:  // PPUDATA
      var data = readBuffer
      readBuffer = ppuRead(v)

      // palette reads are immediate
      if (v & 0x3FFF) >= 0x3F00 { data = ppuRead(v) }
      v = (v &+ vramIncrement) & 0x7FFF

      return data

    default:
      return readBuffer  // open-bus approximation
    }
  }

  public func writeRegister(_ addr: UInt16, _ value: UInt8) {
    switch addr & 7 {
    case 0:  // PPUCTRL
      let wasNMIEnabled = nmiEnabled

      ctrl = value
      decodeCtrl()
      t = (t & 0xF3FF) | (UInt16(value & 0x03) << 10)

      // Enabling NMI while vblank is already set delivers an NMI immediately.
      if !wasNMIEnabled && nmiEnabled && (status & 0x80) != 0 {
        nmiPending = true
      }

    case 1:  // PPUMASK
      mask = value
      decodeMask()

    case 3:  // OAMADDR
      oamAddr = value

    case 4:  // OAMDATA
      oam[Int(oamAddr)] = value
      oamAddr = oamAddr &+ 1

    case 5:  // PPUSCROLL
      if !writeToggle {
        fineX = value & 0x07
        t = (t & 0xFFE0) | (UInt16(value) >> 3)
        writeToggle = true
      } else {
        t = (t & 0x8FFF) | (UInt16(value & 0x07) << 12)
        t = (t & 0xFC1F) | (UInt16(value & 0xF8) << 2)
        writeToggle = false
      }

    case 6:  // PPUADDR
      if !writeToggle {
        t = (t & 0x80FF) | (UInt16(value & 0x3F) << 8)
        writeToggle = true
      } else {
        t = (t & 0xFF00) | UInt16(value)
        v = t
        writeToggle = false
      }

    case 7:  // PPUDATA
      ppuWrite(v, value)
      v = (v &+ vramIncrement) & 0x7FFF

    default:
      break
    }
  }

  /// Direct OAM byte write used by $4014 DMA.
  public func writeOAM(_ value: UInt8) {
    oam[Int(oamAddr)] = value
    oamAddr = oamAddr &+ 1
  }

  // Internal PPU bus

  private func ppuRead(_ address: UInt16) -> UInt8 {
    let a = address & 0x3FFF

    switch a {
    case 0x0000...0x1FFF:
      return cart.chrRead(a)

    case 0x2000...0x3EFF:
      return vram[mirrorNametable(a)]

    default:
      return palette[paletteIndex(a)]
    }
  }

  private func ppuWrite(_ address: UInt16, _ value: UInt8) {
    let a = address & 0x3FFF

    switch a {
    case 0x0000...0x1FFF:
      break  // no-op for CHR-ROM

    case 0x2000...0x3EFF:
      vram[mirrorNametable(a)] = value

    default:
      palette[paletteIndex(a)] = value
    }
  }

  private func mirrorNametable(_ address: UInt16) -> Int {
    // Spy vs Spy is NROM with vertical mirroring (tables map 0,1,0,1).
    let index = Int(address & 0x0FFF)
    let table = index / 0x400
    let offset = index % 0x400

    return (table & 1) * 0x400 + offset
  }

  private func paletteIndex(_ address: UInt16) -> Int {
    var pa = Int(address & 0x1F)

    // $3F10/$14/$18/$1C mirror the background entries $3F00/$04/$08/$0C.
    if pa & 0x13 == 0x10 {
      pa &= ~0x10
    }

    return pa
  }

  // Scroll-address arithmetic

  private func incrementCoarseX() {
    if (v & 0x001F) == 31 {
      v &= ~0x001F
      v ^= 0x0400
    } else {
      v &+= 1
    }
  }

  private func incrementY() {
    if (v & 0x7000) != 0x7000 {
      v &+= 0x1000
    } else {
      v &= ~0x7000

      var y = (v & 0x03E0) >> 5

      if y == 29 {
        y = 0
        v ^= 0x0800
      } else if y == 31 {
        y = 0
      } else {
        y &+= 1
      }

      v = (v & ~0x03E0) | (y << 5)
    }
  }

  private func copyHorizontal() { v = (v & ~0x041F) | (t & 0x041F) }
  private func copyVertical() { v = (v & ~0x7BE0) | (t & 0x7BE0) }

  // Background pipeline

  private func loadShifters() {
    bgShiftLo = (bgShiftLo & 0xFF00) | UInt16(bgLoByte)
    bgShiftHi = (bgShiftHi & 0xFF00) | UInt16(bgHiByte)
    bgAttrShiftLo = (bgAttrShiftLo & 0xFF00) | ((atByte & 0b01) != 0 ? 0xFF : 0x00)
    bgAttrShiftHi = (bgAttrShiftHi & 0xFF00) | ((atByte & 0b10) != 0 ? 0xFF : 0x00)
  }

  private func updateShifters() {
    guard showBackground else { return }

    bgShiftLo <<= 1
    bgShiftHi <<= 1
    bgAttrShiftLo <<= 1
    bgAttrShiftHi <<= 1
  }

  // Sprite evaluation

  private func evaluateSprites(forLine line: Int) {
    spriteCount = 0

    let height = spriteHeight

    for i in 0..<64 {
      let y = Int(oam[i * 4])
      let diff = line - y

      if diff < 0 || diff >= height {
        continue
      }

      if spriteCount >= 8 {
        status |= 0x20  // sprite overflow
        break
      }

      let tile = Int(oam[i * 4 + 1])
      let attr = oam[i * 4 + 2]
      let flipV = (attr & 0x80) != 0
      let flipH = (attr & 0x40) != 0

      var address: UInt16
      if height == 16 {
        var row = diff
        if flipV {
          row = 15 - row
        }

        var tileIndex = tile & 0xFE
        if row >= 8 {
          tileIndex += 1
          row -= 8
        }

        let bank = UInt16(tile & 1) << 12
        address = bank + UInt16(tileIndex) * 16 + UInt16(row)

      } else {
        var row = diff

        if flipV {
          row = 7 - row
        }

        address = spritePatternBase + UInt16(tile) * 16 + UInt16(row)
      }

      var lo = ppuRead(address)
      var hi = ppuRead(address + 8)

      if flipH {
        lo = Self.reverse(lo)
        hi = Self.reverse(hi)
      }

      spriteLo[spriteCount] = lo
      spriteHi[spriteCount] = hi
      spriteAttr[spriteCount] = attr
      spriteX[spriteCount] = Int(oam[i * 4 + 3])
      spriteIsZero[spriteCount] = (i == 0)
      spriteCount += 1
    }
  }

  private static func reverse(_ b: UInt8) -> UInt8 {
    var x = b

    x = (x & 0xF0) >> 4 | (x & 0x0F) << 4
    x = (x & 0xCC) >> 2 | (x & 0x33) << 2
    x = (x & 0xAA) >> 1 | (x & 0x55) << 1

    return x
  }

  // Pixel composition

  private func renderPixel() {
    let x = cycle - 1

    var bgPixel: UInt8 = 0
    var bgPalette: UInt8 = 0

    if showBackground && (x >= 8 || showBackgroundLeft) {
      let mux: UInt16 = 0x8000 >> UInt16(fineX)
      let p0: UInt8 = (bgShiftLo & mux) != 0 ? 1 : 0
      let p1: UInt8 = (bgShiftHi & mux) != 0 ? 1 : 0
      bgPixel = (p1 << 1) | p0

      let a0: UInt8 = (bgAttrShiftLo & mux) != 0 ? 1 : 0
      let a1: UInt8 = (bgAttrShiftHi & mux) != 0 ? 1 : 0
      bgPalette = (a1 << 1) | a0
    }

    var sprPixel: UInt8 = 0
    var sprPalette: UInt8 = 0
    var sprBehind = false
    var sprIsZero = false

    if showSprites && (x >= 8 || showSpritesLeft) {
      // Manual counter rather than `for i in 0..<spriteCount`: this runs per
      // visible pixel and the range iterator doesn't inline under `-Onone`.
      var i = 0
      while i < spriteCount {
        defer { i += 1 }

        let offset = x - spriteX[i]
        if offset >= 0 && offset < 8 {

          let bit = UInt8(7 - offset)
          let lo = (spriteLo[i] >> bit) & 1
          let hi = (spriteHi[i] >> bit) & 1
          let pix = (hi << 1) | lo

          if pix != 0 {
            sprPixel = pix
            sprPalette = (spriteAttr[i] & 0x03) + 4
            sprBehind = (spriteAttr[i] & 0x20) != 0
            sprIsZero = spriteIsZero[i]

            break
          }
        }
      }
    }

    var entry: UInt16 = 0  // offset into palette RAM

    if bgPixel == 0 && sprPixel == 0 {
      entry = 0

    } else if bgPixel == 0 {
      entry = UInt16(sprPalette << 2 | sprPixel)

    } else if sprPixel == 0 {
      entry = UInt16(bgPalette << 2 | bgPixel)

    } else {
      if sprIsZero && showBackground && showSprites && x != 255 {
        status |= 0x40  // sprite 0 hit
      }

      entry =
        sprBehind
        ? UInt16(bgPalette << 2 | bgPixel)
        : UInt16(sprPalette << 2 | sprPixel)
    }

    let color = Int(ppuRead(0x3F00 | entry) & 0x3F)
    fb[scanline * 256 + x] = paletteRGBA[color]
  }

  // Main clock

  /// Advance the PPU cycles by number of dots.
  public func step(_ dots: Int) {
    // A manual counter beats `for _ in 0..<dots` here: in the `-Onone` build the
    // range iterator's calls don't inline, and this is the per-dot hot loop.
    var n = 0
    while n < dots {
      stepDot()
      n += 1
    }
  }

  /// Advance the PPU by one dot.
  private func stepDot() {
    let preRender = scanline == 261
    let visible = scanline < 240
    let renderLine = visible || preRender

    // Vblank start.
    if scanline == 241 && cycle == 1 {
      status |= 0x80
      frameComplete = true

      if nmiEnabled {
        nmiPending = true
      }
    }

    if preRender && cycle == 1 {
      status &= ~0x80  // clear vblank
      status &= ~0x40  // clear sprite 0 hit
      status &= ~0x20  // clear overflow
    }

    if renderingEnabled && renderLine {
      if (cycle >= 1 && cycle <= 256) || (cycle >= 321 && cycle <= 336) {
        updateShifters()

        switch (cycle - 1) % 8 {
        case 0:
          loadShifters()
          ntByte = ppuRead(0x2000 | (v & 0x0FFF))

        case 2:
          let address = 0x23C0 | (v & 0x0C00) | ((v >> 4) & 0x38) | ((v >> 2) & 0x07)
          var at = ppuRead(address)

          if (v & 0x40) != 0 { at >>= 4 }  // bottom half of the 32x32 region
          if (v & 0x02) != 0 { at >>= 2 }  // right half

          atByte = at & 0x03

        case 4:
          let address = bgPatternBase + UInt16(ntByte) * 16 + ((v >> 12) & 0x07)
          bgLoByte = ppuRead(address)

        case 6:
          let address = bgPatternBase + UInt16(ntByte) * 16 + ((v >> 12) & 0x07) + 8
          bgHiByte = ppuRead(address)

        case 7:
          incrementCoarseX()

        default:
          break
        }
      }

      if cycle == 256 {
        incrementY()
      }

      if cycle == 257 {
        loadShifters()
        copyHorizontal()
        evaluateSprites(forLine: preRender ? -1 : scanline)
      }

      if preRender && cycle >= 280 && cycle <= 304 {
        copyVertical()
      }
    }

    if visible && cycle >= 1 && cycle <= 256 {
      renderPixel()
    }

    // Advance the dot counter and clamp the cycle/scanline.
    cycle += 1
    if cycle > 340 {
      cycle = 0
      scanline += 1

      if scanline > 261 {
        scanline = 0
      }
    }
  }
}

/// A complete copy of the PPU's mutable state for snapshots.
struct PPUSnapshot {
  var fb: [UInt32]
  var frameComplete: Bool
  var nmiPending: Bool

  var vram: [UInt8]
  var palette: [UInt8]
  var oam: [UInt8]

  var ctrl: UInt8, mask: UInt8, status: UInt8, oamAddr: UInt8
  var v: UInt16, t: UInt16, fineX: UInt8, writeToggle: Bool, readBuffer: UInt8
  var scanline: Int, cycle: Int

  var ntByte: UInt8, atByte: UInt8, bgLoByte: UInt8, bgHiByte: UInt8
  var bgShiftLo: UInt16, bgShiftHi: UInt16, bgAttrShiftLo: UInt16, bgAttrShiftHi: UInt16

  var spriteCount: Int
  var spriteX: [Int], spriteLo: [UInt8], spriteHi: [UInt8]
  var spriteAttr: [UInt8], spriteIsZero: [Bool]
}

extension PPU {
  func snapshot() -> PPUSnapshot {
    PPUSnapshot(
      fb: fb, frameComplete: frameComplete, nmiPending: nmiPending,
      vram: vram, palette: palette, oam: oam,
      ctrl: ctrl, mask: mask, status: status, oamAddr: oamAddr,
      v: v, t: t, fineX: fineX, writeToggle: writeToggle, readBuffer: readBuffer,
      scanline: scanline, cycle: cycle,
      ntByte: ntByte, atByte: atByte, bgLoByte: bgLoByte, bgHiByte: bgHiByte,
      bgShiftLo: bgShiftLo, bgShiftHi: bgShiftHi,
      bgAttrShiftLo: bgAttrShiftLo, bgAttrShiftHi: bgAttrShiftHi,
      spriteCount: spriteCount,
      spriteX: spriteX, spriteLo: spriteLo, spriteHi: spriteHi,
      spriteAttr: spriteAttr, spriteIsZero: spriteIsZero,
    )
  }

  func restore(_ s: PPUSnapshot) {
    fb = s.fb
    frameComplete = s.frameComplete
    nmiPending = s.nmiPending
    vram = s.vram
    palette = s.palette
    oam = s.oam
    ctrl = s.ctrl
    mask = s.mask
    status = s.status
    oamAddr = s.oamAddr
    v = s.v
    t = s.t
    fineX = s.fineX
    writeToggle = s.writeToggle
    readBuffer = s.readBuffer
    scanline = s.scanline
    cycle = s.cycle
    ntByte = s.ntByte
    atByte = s.atByte
    bgLoByte = s.bgLoByte
    bgHiByte = s.bgHiByte
    bgShiftLo = s.bgShiftLo
    bgShiftHi = s.bgShiftHi
    bgAttrShiftLo = s.bgAttrShiftLo
    bgAttrShiftHi = s.bgAttrShiftHi
    spriteCount = s.spriteCount
    spriteX = s.spriteX
    spriteLo = s.spriteLo
    spriteHi = s.spriteHi
    spriteAttr = s.spriteAttr
    spriteIsZero = s.spriteIsZero

    // Rebuild the decoded register fields from ctrl/mask.
    decodeCtrl()
    decodeMask()
  }
}

import Foundation

/// The NES Controller following a 4021 shift register behaviour. The CPU
/// strobes the controller by writing bit 0 of $4016, then reads one button per
/// read of $4016/$4017, LSB first in the order A, B, Select, Start, Up, Down,
/// Left and then Right.
public final class Controller {

  public struct Button: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let a = Button(rawValue: 1 << 0)
    public static let b = Button(rawValue: 1 << 1)
    public static let select = Button(rawValue: 1 << 2)
    public static let start = Button(rawValue: 1 << 3)
    public static let up = Button(rawValue: 1 << 4)
    public static let down = Button(rawValue: 1 << 5)
    public static let left = Button(rawValue: 1 << 6)
    public static let right = Button(rawValue: 1 << 7)
  }

  /// Live button state
  public var pressedButtons: Button = []

  private var strobe = false
  private var shift: UInt8 = 0

  /// Write to $4016 bit 0. While strobe is high, the shift register is
  /// continuously reloaded.
  public func write(_ value: UInt8) {
    strobe = (value & 1) != 0
    if strobe {
      shift = pressedButtons.rawValue
    }
  }

  /// Read one button. Attempting to make open-bus high bits match real
  /// hardware.
  public func read() -> UInt8 {
    if strobe {
      shift = pressedButtons.rawValue
    }

    let bit = shift & 1
    shift = (shift >> 1) | 0x80  // Shift in 1s after 8 reads

    return 0x40 | bit
  }
}

import Foundation

enum ANSI {
  static let enabled: Bool = {
    if ProcessInfo.processInfo.environment["NO_COLOR"] != nil {
      return false
    }

    return isatty(fileno(stdout)) != 0
  }()

  private static func wrap(_ s: String, _ code: String) -> String {
    enabled
      ? "\u{1B}[\(code)m\(s)\u{1B}[0m"
      : s
  }

  static func bold(_ s: String) -> String { wrap(s, "1") }
  static func dim(_ s: String) -> String { wrap(s, "2") }
  static func yellow(_ s: String) -> String { wrap(s, "33") }
  static func cyan(_ s: String) -> String { wrap(s, "36") }
}

/// Left-justify in `width` columns, truncating with a trailing ellipsis. This
/// is computed before ANSI codes so the alignment should be fine.
func padRight(_ s: String, _ width: Int) -> String {
  if s.count > width {
    if width <= 3 {
      return String(s.prefix(width))
    }

    return s.prefix(width - 3) + "..."
  }

  if s.count == width {
    return s
  }

  return s + String(repeating: " ", count: width - s.count)
}

/// Right-justify in `width` columns, it doesnt truncates.
func padLeft(_ s: String, _ width: Int) -> String {
  if s.count >= width {
    return s
  }

  return String(repeating: " ", count: width - s.count) + s
}

/// A fixed-width `[====    ]` bar sized to `count / maxCount`.
func bar(_ count: Int, max maxCount: Int, width: Int) -> String {
  let filled =
    maxCount > 0
    ? Int((Double(count) / Double(maxCount) * Double(width)).rounded())
    : 0

  let clamped = min(width, max(0, filled))

  return "[" + String(repeating: "=", count: clamped)
    + String(repeating: " ", count: width - clamped) + "]"
}

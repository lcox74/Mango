import AppKit
import SwiftUI

/// Performance numbers for one frame, smoothed for display.
struct PerfMetrics: Equatable {
  /// Wall-clock time spent emulating one frame (ms). Excludes GPU upload/present.
  var emulationMS: Double = 0
  /// Measured frames-per-second (interval between draws, i.e. vsync cadence).
  var fps: Double = 0
  /// Emulation time as a percentage of the 16.67ms frame budget. Over 100% = can't keep up.
  var budgetUsed: Double = 0
}

/// Debug-only performance HUD. Toggle with the backtick (`) key.
struct MetricsOverlay: View {
  let metrics: PerfMetrics

  private var color: Color {
    switch metrics.budgetUsed {
    case ..<80: return .green
    case ..<100: return .yellow
    default: return .red
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(String(format: "emu  %5.2f ms", metrics.emulationMS))
      Text(String(format: "fps  %5.1f", metrics.fps))
      Text(String(format: "load %5.1f%%", metrics.budgetUsed))
    }
    .font(.system(size: 11, design: .monospaced))
    .foregroundStyle(color)
    .padding(.vertical, 4)
    .padding(.horizontal, 6)
    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
  }
}

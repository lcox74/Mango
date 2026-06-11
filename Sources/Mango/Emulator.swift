import AppKit
import Carbon.HIToolbox
import Foundation
import NESCore

@MainActor
final class Emulator: ObservableObject {
  private var nes: Console?
  private var pressed: Controller.Button = []
  private var keyMonitor: Any?

  @Published var metrics = PerfMetrics()
  @Published var showMetrics = false

  private static let frameBudgetMS = 1000.0 / 60.0
  private var emaEmulationMS = 0.0
  private var emaFPS = 0.0
  private var lastTickTime = 0.0
  private var lastPublishTime = 0.0

  init() {
    do {
      if let candidate = Bundle.module.url(forResource: "Spy vs Spy", withExtension: "nes") {
        nes = try Console(
          cartridge: Cartridge(
            data: [UInt8](Data(contentsOf: candidate))
          )
        )
      } else {
        fatalError("Unable to find the 'Spy vs Spy.nes' ROM from the bundle")
      }
    } catch {
      fatalError("Invalid 'Spy vs Spy.nes' ROM")
    }
  }

  func start() {
    installKeyMonitor()
  }

  func stop() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
  }

  func advanceFrame() {
    guard let nes else { return }

    let tickStart = CACurrentMediaTime()
    nes.controller1.pressedButtons = pressed
    nes.stepFrame()
    sampleMetrics(tickStart: tickStart)
  }

  func withFramebuffer<R>(_ body: (UnsafePointer<UInt32>) -> R) -> R? {
    nes?.withFramebuffer(body)
  }

  /// Capture key events
  private func installKeyMonitor() {
    guard keyMonitor == nil
    else { return }

    keyMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown, .keyUp, .flagsChanged]
    ) { [weak self] event in
      guard let self
      else { return event }

      let isFlags = event.type == .flagsChanged
      let isKeyDown = event.type == .keyDown
      let keyCode = event.keyCode
      let shiftDown = event.modifierFlags.contains(.shift)

      let consumed = MainActor.assumeIsolated {
        self.applyKey(
          isFlags: isFlags, isKeyDown: isKeyDown,
          keyCode: keyCode, shiftDown: shiftDown,
        )
      }

      return consumed ? nil : event
    }
  }

  /// Apply a decoded key event. Returns true if it was consumed.
  private func applyKey(
    isFlags: Bool, isKeyDown: Bool, keyCode: UInt16, shiftDown: Bool
  ) -> Bool {

    if isFlags {
      setButton(.select, pressed: shiftDown)
      return false
    }

    // Backtick (`) toggles the perf overlay
    if Int(keyCode) == kVK_ANSI_Grave && isKeyDown {
      showMetrics.toggle()
      return true
    }

    guard let button = Self.button(keyCode: keyCode)
    else { return false }

    setButton(button, pressed: isKeyDown)

    return true
  }

  /// Arrows = D-pad, X = A, Z = B, Return = Start.
  private static func button(keyCode: UInt16) -> Controller.Button? {
    switch Int(keyCode) {
    case kVK_LeftArrow: return .left
    case kVK_RightArrow: return .right
    case kVK_DownArrow: return .down
    case kVK_UpArrow: return .up
    case kVK_Return, kVK_ANSI_KeypadEnter: return .start
    case kVK_ANSI_X: return .a
    case kVK_ANSI_Z: return .b
    default: return nil
    }
  }

  func setButton(_ button: Controller.Button, pressed isDown: Bool) {
    if isDown { pressed.insert(button) } else { pressed.remove(button) }
  }

  private func sampleMetrics(tickStart: Double) {
    let now = CACurrentMediaTime()
    let emulationMS = (now - tickStart) * 1000.0
    emaEmulationMS =
      emaEmulationMS == 0
      ? emulationMS
      : emaEmulationMS * 0.9 + emulationMS * 0.1

    if lastTickTime > 0 {
      let interval = now - lastTickTime
      if interval > 0 {
        let fps = 1.0 / interval
        emaFPS = emaFPS == 0 ? fps : emaFPS * 0.9 + fps * 0.1
      }
    }
    lastTickTime = now

    // Avoid 60 SwiftUI updates/sec for the overlay; refresh ~5x/sec.
    if now - lastPublishTime >= 0.2 {
      lastPublishTime = now
      metrics = PerfMetrics(
        emulationMS: emaEmulationMS,
        fps: emaFPS,
        budgetUsed: emaEmulationMS / Self.frameBudgetMS * 100.0,
        step: nes?.frameCount ?? 0
      )
    }
  }
}

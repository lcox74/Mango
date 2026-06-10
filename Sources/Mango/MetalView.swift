import MetalKit
import SwiftUI

struct MetalView: NSViewRepresentable {
  let emulator: Emulator

  func makeCoordinator() -> MetalRenderer {
    guard
      let device = MTLCreateSystemDefaultDevice(),
      let renderer = MetalRenderer(emulator: emulator, device: device)

    else {
      fatalError("Metal is unavailable on this system.")
    }

    return renderer
  }

  func makeNSView(context: Context) -> MTKView {
    let view = MTKView(frame: .zero, device: context.coordinator.device)

    view.delegate = context.coordinator
    view.colorPixelFormat = .bgra8Unorm
    view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    view.preferredFramesPerSecond = 60
    view.isPaused = false
    view.enableSetNeedsDisplay = false
    view.framebufferOnly = true

    return view
  }

  func updateNSView(_ nsView: MTKView, context: Context) {}
}

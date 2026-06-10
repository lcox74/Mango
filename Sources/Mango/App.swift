import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    DispatchQueue.main.async {
      NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}

@main
struct MangoApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var emulator = Emulator()

  var body: some Scene {
    WindowGroup {
      ContentView(emulator: emulator)
    }
    .windowResizability(.contentSize)
  }
}

struct ContentView: View {
  @ObservedObject var emulator: Emulator

  var body: some View {
    ZStack {
      Color.black

      MetalView(emulator: emulator)
        .aspectRatio(256.0 / 240.0, contentMode: .fit)

    }
    .frame(width: 512, height: 480)
    .onAppear { emulator.start() }
    .overlay(alignment: .topLeading) {
      if emulator.showMetrics {
        MetricsOverlay(metrics: emulator.metrics)
          .padding(8)
      }
    }
  }
}

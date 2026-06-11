import Foundation
import NESCore

// The workload side of the profiler: hold the emulator inside one scene and run
// it as a steady-state load for the macOS `sample` tool to attach to.

private let romName = "Spy vs Spy.nes"

extension Duration {
  /// The duration as a Double number of seconds.
  var asSeconds: Double {
    let c = components
    return Double(c.seconds) + Double(c.attoseconds) / 1e18
  }
}

/// Load the ROM into a fresh console, or bail out with a clear message.
private func loadConsole(rom name: String) -> Console {
  let url = URL(fileURLWithPath: name)

  guard FileManager.default.fileExists(atPath: url.path)
  else { fatalError("There is no '\(name)' ROM") }

  do {
    let data = [UInt8](try Data(contentsOf: url))
    return try Console(cartridge: Cartridge(data: data))
  } catch {
    fatalError("Failed to load '\(name)': \(error)")
  }
}

/// Run one scene as a steady-state workload to be sampled by macOS `sample`.
/// Steps up to the scene, snapshots, signals readiness, then loops the scene's
/// frames (rewinding each pass) until `seconds` elapse, writing the timing
/// sidecar on the way out.
func runWorkload(scene: Scene, seconds: Double, statsPath: String) {
  let nes = loadConsole(rom: romName)

  // Step up to the scene, then snapshot so we can rewind to exactly here.
  for _ in 0..<scene.warmup { nes.stepFrame() }
  let anchor = nes.snapshot()

  // Signal that warmup is done and the steady-state loop is about to begin
  let readyPath = statsPath.replacingOccurrences(of: ".stats.json", with: ".ready")
  FileManager.default.createFile(atPath: readyPath, contents: nil)

  // A cheap fingerprint of the screen at the anchor frame
  let screen = nes.framebufferSnapshot().reduce(UInt32(0)) { $0 &* 31 &+ $1 }
  logErr(
    String(
      format: "profiling '%@' (steps %d-%d) for %.0fs, pid %d, screen %08x",
      scene.name,
      scene.startFrame, scene.endFrame,
      seconds,
      getpid(),
      screen,
    ),
  )

  // Loop the scene: play it through, rewind, repeat, until budget timeout.
  let clock = ContinuousClock()
  let budget = Duration.seconds(seconds)
  var frames = 0
  let start = clock.now

  loop: while true {
    for _ in 0..<scene.span {
      nes.stepFrame()
      frames += 1

      if clock.now - start >= budget {
        break loop
      }
    }
    nes.restore(anchor)
  }

  let elapsed = (clock.now - start).asSeconds
  let msPerFrame = elapsed * 1000.0 / Double(frames)

  logErr(String(format: "ran %d frames, %.2f ms/frame", frames, msPerFrame))

  // Hand the timing to the `report` step via a sidecar file.
  let stats = SceneStats(
    name: scene.name,
    startFrame: scene.startFrame, endFrame: scene.endFrame,
    msPerFrame: msPerFrame, budgetMS: 1000.0 / 60.0,
  )

  stats.write(to: statsPath)
}

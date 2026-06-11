import Foundation
import NESCore

let romName = "Spy vs Spy.nes"
let secondsToProfile = 15.0

/// Write a line to stderr, keeping these notes out of the profiler's sampled
/// (stdout) output.
func logErr(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Load the ROM into a fresh console, or bail out with a clear message.
func loadConsole(rom name: String) -> Console {
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

let nes = loadConsole(rom: romName)

// Warm up past the boot screen so the sample captures steady-state work.
for _ in 0..<60 { nes.stepFrame() }

logErr("profiling for \(secondsToProfile)s, pid \(getpid())")

var frames = 0
let start = Date()
while Date().timeIntervalSince(start) < secondsToProfile {
  nes.stepFrame()
  frames += 1
}

let msPerFrame = Date().timeIntervalSince(start) * 1000.0 / Double(frames)
logErr(String(format: "ran %d frames, %.2f ms/frame", frames, msPerFrame))

import Foundation

/// One profileable screen scene, identified by the frame ("step") range shown
/// in the Mango debug HUD. This step is PPU Step.
struct Scene {
  let name: String
  let startFrame: Int  // first frame of the scene
  let endFrame: Int  // last frame of the scene

  /// Frames to step from power-on before the scene begins.
  var warmup: Int { startFrame }

  /// Frames that make up one pass through the scene.
  var span: Int { endFrame - startFrame + 1 }

  static let all: [Scene] = [
    Scene(name: "start", startFrame: 0, endFrame: 250),
    Scene(name: "menu", startFrame: 251, endFrame: 900),
    Scene(name: "autoplay", startFrame: 900, endFrame: 1800),
  ]

  static func named(_ name: String) -> Scene? {
    all.first { $0.name == name }
  }

  /// Default sidecar path used to hand the workload's timing to the `report`
  /// step. Mirrors the `/tmp/mango-sample-<scene>.txt` sample file naming.
  var defaultStatsPath: String { "/tmp/mango-sample-\(name).stats.json" }
}

/// Timing the `report` step can't get from the sample file: written by the
/// workload run and read back when rendering.
struct SceneStats: Codable {
  let name: String
  let startFrame: Int
  let endFrame: Int
  let msPerFrame: Double
  let budgetMS: Double

  func write(to path: String) {
    let encoder = JSONEncoder()

    encoder.outputFormatting = .prettyPrinted

    guard let data = try? encoder.encode(self)
    else { return }

    try? data.write(to: URL(fileURLWithPath: path))
  }

  static func read(from path: String) -> SceneStats? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path))
    else { return nil }

    return try? JSONDecoder().decode(SceneStats.self, from: data)
  }
}

func defaultStatsPath(forSample sample: String) -> String {
  if sample.hasSuffix(".txt") {
    return String(sample.dropLast(4)) + ".stats.json"
  }

  return sample + ".stats.json"
}

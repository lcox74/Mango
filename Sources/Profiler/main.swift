import Foundation

// The profiler runs in one of two modes:
//
//   Profiler <scene> [seconds] [stats-path]
//   Profiler report <sample-file>...
//
// The '<scene>' will run a predefined scene worload to profile and be sampled
// by the macOS `sample` tool. The 'report' mode will parse the sample reports
// and present them in some readable way.

/// Write a line to stderr, keeping these notes out of the profiler's sampled
/// (stdout) output.
func logErr(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}

let args = Array(CommandLine.arguments.dropFirst())

if args.first == "report" {
  runReport(sampleFiles: Array(args.dropFirst()))
  exit(0)
}

// Workload mode.
let scene = Scene.named(args.first ?? "") ?? Scene.all.last!

let seconds = args.dropFirst().first.flatMap { Double($0) } ?? 15.0

let statsPath = args.dropFirst(2).first ?? scene.defaultStatsPath

runWorkload(scene: scene, seconds: seconds, statsPath: statsPath)

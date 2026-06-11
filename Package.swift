// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "NESCore",
  platforms: [.macOS(.v26)],
  products: [
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(name: "NESCore", targets: ["NESCore"]),
    .executable(name: "Mango", targets: ["Mango"]),
    .executable(name: "Profiler", targets: ["Profiler"]),
  ],
  targets: [
    // Targets are the basic building blocks of a package, defining a module or a test suite.
    // Targets can depend on other targets in this package and products from dependencies.
    .target(name: "NESCore"),
    .executableTarget(
      name: "Mango",
      dependencies: ["NESCore"],
      resources: [.copy("Spy vs Spy.nes")]
    ),
    .executableTarget(name: "Profiler", dependencies: ["NESCore"]),
    .testTarget(
      name: "NESCoreTests",
      dependencies: ["NESCore"]
    ),
  ],
  swiftLanguageModes: [.v6]
)

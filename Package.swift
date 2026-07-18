// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "TeaAway",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "teaway", targets: ["TeaAway"])
  ],
  targets: [
    .target(name: "TeaAwayCore"),
    .executableTarget(
      name: "TeaAway",
      dependencies: ["TeaAwayCore"]
    ),
    .testTarget(
      name: "TeaAwayCoreTests",
      dependencies: ["TeaAwayCore"],
      path: "tests/TeaAwayCoreTests"
    ),
  ]
)

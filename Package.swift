// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BluetoothCodex",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "BridgeCore", targets: ["BridgeCore"]),
               .executable(name: "BluetoothCodex", targets: ["BridgeMac"]),
               .executable(name: "RelayHarness", targets: ["BridgeRelay"])],
    targets: [.target(name: "BridgeCore"),
              .executableTarget(name: "BridgeMac", dependencies: ["BridgeCore"]),
              .executableTarget(name: "BridgeRelay", dependencies: ["BridgeCore"])])

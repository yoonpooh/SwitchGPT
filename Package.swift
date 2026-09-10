// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SwitchGPT", defaultLocalization: "en", platforms: [.macOS(.v14)], products: [.executable(name: "SwitchGPT", targets: ["SwitchGPT"])], targets: [.executableTarget(name: "SwitchGPT", resources: [.process("Resources")]), .testTarget(name: "SwitchGPTTests", dependencies: ["SwitchGPT"])])

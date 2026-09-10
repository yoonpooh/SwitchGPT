// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CodexAccountSwitch", defaultLocalization: "en", platforms: [.macOS(.v14)], products: [.executable(name: "CodexAccountSwitch", targets: ["CodexAccountSwitch"])], targets: [.executableTarget(name: "CodexAccountSwitch", resources: [.process("Resources")]), .testTarget(name: "CodexAccountSwitchTests", dependencies: ["CodexAccountSwitch"])])

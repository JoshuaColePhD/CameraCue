// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Teleprompter",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TeleprompterCore", targets: ["TeleprompterCore"]),
        .executable(name: "Teleprompter", targets: ["TeleprompterApp"])
    ],
    targets: [
        .target(name: "TeleprompterCore"),
        .executableTarget(name: "TeleprompterApp", dependencies: ["TeleprompterCore"], resources: [.process("Resources")]),
        .testTarget(name: "TeleprompterCoreTests", dependencies: ["TeleprompterCore"]),
        .testTarget(name: "TeleprompterAppTests", dependencies: ["TeleprompterApp"])
    ],
    swiftLanguageModes: [.v6]
)

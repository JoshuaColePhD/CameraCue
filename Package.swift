// swift-tools-version: 6.0
import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Teleprompter",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TeleprompterCore", targets: ["TeleprompterCore"]),
        .executable(name: "Teleprompter", targets: ["TeleprompterApp"]),
        .executable(name: "VoiceFollowEvaluation", targets: ["VoiceFollowEvaluation"]),
        .executable(name: "SpeechEvaluation", targets: ["SpeechEvaluation"])
    ],
    targets: [
        .target(name: "TeleprompterCore"),
        .target(name: "CameraCueSpeech", dependencies: ["TeleprompterCore"]),
        .executableTarget(name: "SpeechEvaluation", dependencies: ["CameraCueSpeech", "TeleprompterCore"], exclude: ["Info.plist"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", packageDirectory + "/Sources/SpeechEvaluation/Info.plist"])]),
        .executableTarget(name: "TeleprompterApp", dependencies: ["TeleprompterCore", "CameraCueSpeech"], resources: [.process("Resources")]),
        .executableTarget(name: "VoiceFollowEvaluation", dependencies: ["TeleprompterCore"], resources: [.process("Fixtures")]),
        .testTarget(name: "CameraCueSpeechTests", dependencies: ["CameraCueSpeech"]),
        .testTarget(name: "TeleprompterCoreTests", dependencies: ["TeleprompterCore"]),
        .testTarget(name: "TeleprompterAppTests", dependencies: ["TeleprompterApp"])
    ],
    swiftLanguageModes: [.v6]
)

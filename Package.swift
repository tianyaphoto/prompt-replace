// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PromptReplace",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PromptReplace",
            path: "Sources/PromptReplace"
        ),
        .testTarget(
            name: "PromptReplaceTests",
            dependencies: ["PromptReplace"],
            path: "Tests/PromptReplaceTests"
        ),
    ]
)

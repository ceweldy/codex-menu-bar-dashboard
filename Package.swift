// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexMenuBar",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "CodexMenuBar",
            exclude: ["Resources"]
        )
    ]
)

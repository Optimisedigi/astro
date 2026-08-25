// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Universe",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Universe",
            path: "Sources/Universe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

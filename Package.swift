// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TamaClone",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "TamaClone",
            path: "Sources/TamaClone",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Universe",
    platforms: [.macOS(.v15)],
    dependencies: [
        // The input-bar orb: the library author's own SwiftUI port. Vendored (MIT).
        .package(path: "Vendor/ThinkingOrbsKit"),
        // The panel's border glow. Vendored (MIT); its Metal shader only
        // compiles in the Xcode build, so `swift build` draws no beam.
        .package(path: "Vendor/BorderBeamKit"),
    ],
    targets: [
        .executableTarget(
            name: "Universe",
            dependencies: ["ThinkingOrbsKit", "BorderBeamKit"],
            path: "Sources/Universe",
            resources: [.copy("ResearchTemplates")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

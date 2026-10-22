// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Osprey",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OspreyCore", targets: ["OspreyCore"]),
        .executable(name: "osprey", targets: ["osprey"]),
        .executable(name: "OspreyBar", targets: ["OspreyBar"]),
    ],
    targets: [
        .target(
            name: "OspreyCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "osprey",
            dependencies: ["OspreyCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "OspreyBar",
            dependencies: ["OspreyCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OspreyCoreTests",
            dependencies: ["OspreyCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

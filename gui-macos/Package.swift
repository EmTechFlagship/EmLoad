// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EmLoadMac",
    platforms: [
        // Liquid Glass is enabled at runtime on macOS 26+, while the same
        // binary still runs on macOS 13 with the older material fallback.
        .macOS(.v13),
    ],
    products: [
        .executable(name: "EmLoadMac", targets: ["EmLoadMac"]),
    ],
    dependencies: [
        .package(path: "../EmLoadServer"),
    ],
    targets: [
        .executableTarget(
            name: "EmLoadMac",
            dependencies: [
                .product(name: "EmLoadServerKit", package: "EmLoadServer"),
            ],
            path: "Sources/EmLoadMac"
        ),
        .testTarget(
            name: "EmLoadMacTests",
            dependencies: ["EmLoadMac"],
            path: "Tests/EmLoadMacTests"
        ),
    ]
)

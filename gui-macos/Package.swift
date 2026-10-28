// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EmLoadMac",
    platforms: [
        .macOS("15.0"),
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

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EmLoadServer",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "EmLoadServerKit", targets: ["EmLoadServerKit"]),
        .executable(name: "emloadserver", targets: ["emloadserver"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/SideStore/SideSign",
            revision: "752d1ef602aa792a432ffa1e71646dc1ecf7363c"
        )
    ],
    targets: [
        .target(
            name: "EmLoadServerKit",
            dependencies: [.product(name: "SideSign", package: "SideSign")],
            path: "Sources/EmLoadServer",
            resources: [.copy("Resources/EmLoadStore.png")]
        ),
        .executableTarget(
            name: "emloadserver",
            dependencies: ["EmLoadServerKit"],
            path: "Sources/EmLoadServerMain"
        ),
        .testTarget(
            name: "EmLoadServerTests",
            dependencies: [
                "EmLoadServerKit",
                .product(name: "SideSign", package: "SideSign")
            ]
        )
    ]
)

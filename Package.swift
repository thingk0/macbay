// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MacBay",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "MacBayKit",
            targets: ["MacBayKit"]
        ),
        .library(
            name: "MacBayTUI",
            targets: ["MacBayTUI"]
        ),
        .executable(
            name: "macbay",
            targets: ["macbay"]
        ),
        .executable(
            name: "mb",
            targets: ["macbay"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.5.0"
        )
    ],
    targets: [
        .target(
            name: "MacBayKit"
        ),
        .target(
            name: "MacBayTUI",
            dependencies: ["MacBayKit"]
        ),
        .executableTarget(
            name: "macbay",
            dependencies: [
                "MacBayKit",
                "MacBayTUI",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "MacBayKitTests",
            dependencies: ["MacBayKit"]
        ),
        .testTarget(
            name: "MacBayTUITests",
            dependencies: ["MacBayTUI", "MacBayKit"]
        )
    ],
    swiftLanguageVersions: [.v5]
)

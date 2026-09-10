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
        .executableTarget(
            name: "macbay",
            dependencies: [
                "MacBayKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "MacBayKitTests",
            dependencies: ["MacBayKit"]
        )
    ],
    swiftLanguageVersions: [.v5]
)

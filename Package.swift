// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clawbridge",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "clawbridge", targets: ["Clawbridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "Clawbridge",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)

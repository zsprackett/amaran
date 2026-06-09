// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "amaran",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "AmaranCore", targets: ["AmaranCore"]),
        .executable(name: "AmaranHelper", targets: ["AmaranHelper"]),
        .executable(name: "amaran", targets: ["amaran"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "AmaranCore",
            path: "Sources/AmaranCore"
        ),
        .target(
            name: "AmaranCLI",
            dependencies: [
                "AmaranCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/AmaranCLI"
        ),
        .executableTarget(
            name: "amaran",
            dependencies: [
                "AmaranCLI",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/amaran"
        ),
        .executableTarget(
            name: "AmaranHelper",
            dependencies: ["AmaranCore"],
            path: "Sources/AmaranHelper",
            // The native BLE/mesh code was written and shipped under the Swift 5
            // language mode (raw `swiftc`). Keep it there rather than refactor
            // ~5k lines of working CoreBluetooth code for Swift 6 strict
            // concurrency. AmaranCore stays on the default Swift 6 mode.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AmaranCoreTests",
            dependencies: ["AmaranCore"],
            path: "tests/AmaranCoreTests"
        ),
        .testTarget(
            name: "AmaranCLITests",
            dependencies: ["AmaranCLI"],
            path: "tests/AmaranCLITests"
        )
    ]
)

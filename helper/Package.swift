// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeetMeHelper",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "MeetMeHelper", targets: ["App"])
    ],
    dependencies: [
        // 1.1.0 provides bounded-memory incremental file loading for long recordings.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "1.1.0")
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            path: "Sources/App"
        ),
        .testTarget(
            name: "AppTests",
            dependencies: ["App"],
            path: "Tests/AppTests"
        )
    ],
    swiftLanguageModes: [.v5]
)

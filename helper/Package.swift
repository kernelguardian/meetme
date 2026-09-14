// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeetMeHelper",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "MeetMeHelper", targets: ["App"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [],
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

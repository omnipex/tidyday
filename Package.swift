// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TidyDay",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "TidyDay",
            path: "Sources/TidyDay",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

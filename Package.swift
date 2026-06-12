// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "scrollwm",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WindowLab",
            path: "Sources/WindowLab"
        )
    ]
)

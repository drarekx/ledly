// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Ledly",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Ledly",
            path: "Sources/Ledly"
        )
    ]
)

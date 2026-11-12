// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Lapang",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Lapang", path: "Sources/Lapang"),
    ]
)

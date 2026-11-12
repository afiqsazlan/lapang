// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Lapang",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "Lapang",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Lapang",
            // build.sh puts Sparkle.framework in Lapang.app/Contents/Frameworks
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)

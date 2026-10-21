// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "meetrec",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")
    ],
    targets: [
        .executableTarget(
            name: "meetrec",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/meetrec",
            swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)

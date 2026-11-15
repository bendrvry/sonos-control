// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SonosControl",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "SonosCore"),
        .executableTarget(name: "SonosControl", dependencies: ["SonosCore"]),
        .executableTarget(name: "SonosProbe", dependencies: ["SonosCore"]),
        .executableTarget(name: "SonosChecks", dependencies: ["SonosCore"], path: "Tests/SonosCoreTests")
    ]
)

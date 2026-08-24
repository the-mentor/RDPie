// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "tcc-attribution",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "probe-agent")
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RDPie",
    platforms: [.macOS(.v14)],   // Spec §3.4
    products: [
        .library(name: "RdpieCapture", targets: ["RdpieCapture"]),
        .executable(name: "rdpied", targets: ["rdpied"]),
    ],
    targets: [
        .target(name: "RdpieCapture"),
        .executableTarget(name: "rdpied", dependencies: ["RdpieCapture"]),
        .testTarget(name: "RdpieCaptureTests", dependencies: ["RdpieCapture"]),
    ]
)

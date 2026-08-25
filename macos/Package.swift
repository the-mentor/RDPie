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
        .target(name: "RdpieCapture", dependencies: ["CRdpieCore"]),
        .systemLibrary(name: "CRdpieCore", path: "Sources/CRdpieCore"),
        .executableTarget(
            name: "rdpied",
            dependencies: ["RdpieCapture", "CRdpieCore"],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedFramework("SystemConfiguration"),
                .unsafeFlags(["-L../target/release", "-lrdpie_core"])
            ]
        ),
        .testTarget(name: "RdpieCaptureTests", dependencies: ["RdpieCapture", "CRdpieCore"]),
    ]
)

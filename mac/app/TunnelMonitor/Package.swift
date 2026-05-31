// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TunnelMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TunnelMonitor", targets: ["TunnelMonitor"])
    ],
    targets: [
        .executableTarget(
            name: "TunnelMonitor",
            path: "Sources/TunnelMonitor"
        )
    ]
)

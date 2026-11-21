// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiskScope",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DiskScope", path: "Sources/DiskScope"),
        .testTarget(name: "DiskScopeTests", dependencies: ["DiskScope"], path: "Tests/DiskScopeTests"),
    ]
)

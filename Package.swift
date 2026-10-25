// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RazerLite",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RazerLiteCore", targets: ["RazerLiteCore"]),
        .executable(name: "RazerLite", targets: ["RazerLite"]),
        .executable(name: "razerlite-probe", targets: ["RazerLiteProbe"])
    ],
    targets: [
        .target(name: "RazerLiteCore", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "RazerLite", dependencies: ["RazerLiteCore"]),
        .executableTarget(name: "RazerLiteProbe", dependencies: ["RazerLiteCore"]),
        .testTarget(name: "RazerLiteCoreTests", dependencies: ["RazerLiteCore"])
    ]
)

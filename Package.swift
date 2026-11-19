// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RetroTerm",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CPTY", path: "Sources/CPTY"),
        .target(name: "RetroTermCore", dependencies: ["CPTY"], path: "Sources/RetroTermCore"),
        .target(name: "RetroBasic", path: "Sources/RetroBasic"),
        .executableTarget(
            name: "RetroTerm",
            dependencies: ["RetroTermCore", "RetroBasic"],
            path: "Sources/RetroTerm"
        ),
        .testTarget(name: "RetroTermCoreTests", dependencies: ["RetroTermCore"], path: "Tests/RetroTermCoreTests"),
        .testTarget(name: "RetroBasicTests", dependencies: ["RetroBasic", "RetroTermCore"], path: "Tests/RetroBasicTests"),
    ]
)

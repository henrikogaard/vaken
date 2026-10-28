// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "vaken",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "VakenCore", path: "Sources/VakenCore"),
        .target(name: "VakenService", dependencies: ["VakenCore"]),
        .executableTarget(name: "vaken-helper", dependencies: ["VakenCore", "VakenService"], path: "Sources/VakenHelper"),
        .executableTarget(
            name: "vaken",
            dependencies: ["VakenCore", "VakenService", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Vaken",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "VakenTests",
            dependencies: ["VakenCore", "VakenService", "vaken"],
            path: "Tests/VakenTests"
        ),
    ]
)

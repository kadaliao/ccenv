// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ccenv",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CCEnvCore", targets: ["CCEnvCore"]),
        .executable(name: "CCEnv", targets: ["CCEnv"]),
        .executable(name: "ccenv-parity", targets: ["ccenv-parity"]),
    ],
    targets: [
        .target(
            name: "CCEnvCore",
            path: "Sources/CCEnvCore"
        ),
        .executableTarget(
            name: "CCEnv",
            dependencies: ["CCEnvCore"],
            path: "Sources/CCEnv"
        ),
        .executableTarget(
            name: "ccenv-parity",
            dependencies: ["CCEnvCore"],
            path: "Sources/ccenv-parity"
        ),
        .testTarget(
            name: "CCEnvCoreTests",
            dependencies: ["CCEnvCore"],
            path: "Tests/CCEnvCoreTests"
        ),
    ]
)

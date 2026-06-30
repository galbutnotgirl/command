// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeCommand",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "313feb4bd692780a9a5b5fa9048fdb119486dde8"
        )
    ],
    targets: [
        .executableTarget(
            name: "ClaudeCommand",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: ".",
            exclude: ["icon.png"],
            linkerSettings: [
                .linkedFramework("Carbon"),
            ]
        )
    ]
)

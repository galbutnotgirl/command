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
        // Pure logic (no NSApplication/hotkey/socket side effects) split out so
        // it's unit-testable in isolation — see Tests/ClaudeCommandCoreTests.
        // The executable target below imports it for the real app.
        .target(
            name: "ClaudeCommandCore",
            path: "Sources/ClaudeCommandCore"
        ),
        .executableTarget(
            name: "ClaudeCommand",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                "ClaudeCommandCore",
            ],
            path: ".",
            exclude: ["icon.png", "Sources", "Tests"],
            linkerSettings: [
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "ClaudeCommandCoreTests",
            dependencies: ["ClaudeCommandCore"],
            path: "Tests/ClaudeCommandCoreTests"
        ),
    ]
)

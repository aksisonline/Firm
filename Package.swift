// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Firm",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "MultitouchShim",
            path: "Sources/MultitouchShim"
        ),
        .executableTarget(
            name: "Firm",
            dependencies: ["MultitouchShim"],
            path: "Sources/Firm",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)

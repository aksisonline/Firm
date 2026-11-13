// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TrackpadPen",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "MultitouchShim",
            path: "Sources/MultitouchShim"
        ),
        .executableTarget(
            name: "TrackpadPen",
            dependencies: ["MultitouchShim"],
            path: "Sources/TrackpadPen",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)

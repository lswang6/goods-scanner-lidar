// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BoxMeasureKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "BoxMeasureKit", targets: ["BoxMeasureKit"])],
    targets: [
        .target(name: "BoxMeasureKit"),
        // macOS dev tool (SPEC §11 D6); not in `products`, so the iOS app never builds it.
        .executableTarget(name: "bmk-replay", dependencies: ["BoxMeasureKit"]),
        .testTarget(name: "BoxMeasureKitTests", dependencies: ["BoxMeasureKit"], resources: [.copy("Fixtures")]),
    ]
)

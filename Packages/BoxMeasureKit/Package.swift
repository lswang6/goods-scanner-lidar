// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BoxMeasureKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "BoxMeasureKit", targets: ["BoxMeasureKit"])],
    targets: [
        .target(name: "BoxMeasureKit"),
        .testTarget(name: "BoxMeasureKitTests", dependencies: ["BoxMeasureKit"]),
    ]
)

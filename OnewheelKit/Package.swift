// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OnewheelKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OnewheelKit", targets: ["OnewheelKit"]),
    ],
    targets: [
        .target(name: "OnewheelKit"),
        .testTarget(name: "OnewheelKitTests", dependencies: ["OnewheelKit"]),
    ]
)

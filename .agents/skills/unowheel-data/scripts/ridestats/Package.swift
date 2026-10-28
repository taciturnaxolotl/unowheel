// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ridestats",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../../../../OnewheelKit")],
    targets: [.executableTarget(name: "ridestats", dependencies: ["OnewheelKit"])]
)

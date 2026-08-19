// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Tim",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Cross-platform core: tabs, sites, ownership matching, edit
        // tracking, and the publish/round-trip logic. Compiles for macOS,
        // iOS, and iPadOS.
        .library(name: "TimKit", targets: ["TimKit"]),
        // The macOS app.
        .executable(name: "Tim", targets: ["Tim"])
    ],
    targets: [
        .target(name: "TimKit", path: "Sources/TimKit"),
        .executableTarget(name: "Tim", dependencies: ["TimKit"], path: "Sources/Tim")
    ]
)

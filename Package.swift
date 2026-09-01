// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Tim",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        // Cross-platform core: tabs, sites, ownership matching, edit
        // tracking, and the publish/round-trip logic. Compiles for macOS,
        // iOS, and iPadOS.
        .library(name: "TimKit", targets: ["TimKit"]),
        // The macOS app.
        .executable(name: "Tim", targets: ["Tim"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(name: "TimKit", path: "Sources/TimKit"),
        .executableTarget(
            name: "Tim",
            dependencies: [
                "TimKit",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Tim"
        )
    ]
)

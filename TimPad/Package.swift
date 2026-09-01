// swift-tools-version: 5.9

// TimPad — Tim on the iPad. A Swift Playgrounds-format app package:
// open this folder in Xcode to run in the Simulator or on a device,
// or send it to Swift Playgrounds on the iPad itself.
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "TimPad",
    platforms: [.iOS("26.0")],
    products: [
        .iOSApplication(
            name: "TimPad",
            targets: ["TimPad"],
            bundleIdentifier: "com.gabrieljeffrey.timpad",
            teamIdentifier: "VDNJRV3PR9",
            displayVersion: "0.1",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .pencil),
            accentColor: .presetColor(.yellow),
            supportedDeviceFamilies: [.pad, .phone],
            supportedInterfaceOrientations: [.portrait, .landscapeLeft, .landscapeRight],
            capabilities: [
                .outgoingNetworkConnections()
            ]
        )
    ],
    dependencies: [
        .package(path: ".."),
        // Pure-Swift SSH/SFTP — publishing without Process, as the
        // Publisher.swift architecture note always planned for iOS.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.7.0")
    ],
    targets: [
        .executableTarget(
            name: "TimPad",
            dependencies: [
                .product(name: "TimKit", package: "Tim"),
                .product(name: "Citadel", package: "Citadel")
            ],
            path: "Sources"
        )
    ]
)

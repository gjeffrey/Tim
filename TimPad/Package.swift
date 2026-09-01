// swift-tools-version: 5.9

// TimPad — Tim on the iPad. A Swift Playgrounds-format app package:
// open this folder in Xcode to run in the Simulator or on a device,
// or send it to Swift Playgrounds on the iPad itself.
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "TimPad",
    platforms: [.iOS("17.0")],
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
        .package(path: "..")
    ],
    targets: [
        .executableTarget(
            name: "TimPad",
            dependencies: [
                .product(name: "TimKit", package: "Tim")
            ],
            path: "Sources"
        )
    ]
)

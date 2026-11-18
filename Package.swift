// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "AmphoraKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2)
    ],
    products: [
        .library(name: "AmphoraKit", targets: ["AmphoraKit"]),
        .library(name: "AmphoraKitTestSupport", targets: ["AmphoraKitTestSupport"])
    ],
    targets: [
        .target(name: "AmphoraKit"),
        .target(name: "AmphoraKitTestSupport", dependencies: ["AmphoraKit"]),
        .testTarget(name: "AmphoraKitTests", dependencies: ["AmphoraKit", "AmphoraKitTestSupport"])
    ]
)

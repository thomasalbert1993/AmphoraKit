// swift-tools-version: 6.3

import PackageDescription
import CompilerPluginSupport

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
        .library(name: "AmphoraKitMacros", targets: ["AmphoraKitMacros"]),
        .library(name: "AmphoraKitTestSupport", targets: ["AmphoraKitTestSupport"])
    ],
    dependencies: [
        // Only the macros product pulls it in.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "601.0.0"..<"700.0.0")
    ],
    targets: [
        .target(name: "AmphoraKit"),
        .target(name: "AmphoraKitTestSupport", dependencies: ["AmphoraKit"]),
        .testTarget(name: "AmphoraKitTests", dependencies: ["AmphoraKit", "AmphoraKitTestSupport"]),

        // The macro declarations consumers import…
        .target(name: "AmphoraKitMacros", dependencies: ["AmphoraKit", "AmphoraKitMacrosPlugin"]),
        // … and their implementation, run by the compiler.
        .macro(
            name: "AmphoraKitMacrosPlugin",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
            ]
        ),
        .testTarget(
            name: "AmphoraKitMacrosTests",
            dependencies: [
                "AmphoraKitMacros",
                "AmphoraKitMacrosPlugin",
                "AmphoraKitTestSupport",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax")
            ]
        )
    ]
)

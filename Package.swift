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
        // The macros' implementation, a compiler plugin built with the package.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "601.0.0"..<"700.0.0")
    ],
    targets: [
        // The runtime and the macro declarations: `import AmphoraKit` brings `@Entity` too.
        .target(name: "AmphoraKit", dependencies: ["AmphoraKitMacrosPlugin"]),
        .target(name: "AmphoraKitTestSupport", dependencies: ["AmphoraKit"]),
        .testTarget(name: "AmphoraKitTests", dependencies: ["AmphoraKit", "AmphoraKitTestSupport"]),

        // Kept for `import AmphoraKitMacros`: re-exports AmphoraKit.
        .target(name: "AmphoraKitMacros", dependencies: ["AmphoraKit"]),
        // The macros' implementation, run by the compiler.
        .macro(
            name: "AmphoraKitMacrosPlugin",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
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

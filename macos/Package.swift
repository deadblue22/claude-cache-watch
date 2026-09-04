// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClaudeCacheWatch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeCacheWatch", targets: ["ClaudeCacheWatch"]),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeCacheWatch",
            path: "Sources/ClaudeCacheWatch"
        ),
    ],
    swiftLanguageModes: [.v5]
)

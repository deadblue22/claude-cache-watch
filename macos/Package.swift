// swift-tools-version: 5.10

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
    swiftLanguageVersions: [.v5]
)

// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CuySearchManager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CuySearchManager", targets: ["CuySearchManager"]),
    ],
    targets: [
        .executableTarget(name: "CuySearchManager"),
    ],
    swiftLanguageModes: [.v5]
)

// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LIT",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LIT", targets: ["Lit"]),
        .executable(name: "lit-cli", targets: ["lit-cli"]),
    ],
    targets: [
        .target(name: "LitCore"),
        .executableTarget(name: "Lit", dependencies: ["LitCore"]),
        .executableTarget(name: "lit-cli", dependencies: ["LitCore"]),
    ]
)

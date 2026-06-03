// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Tokenomics",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Tokenomics",
            path: "Sources/Tokenomics"
        )
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BLEChat",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "BLEChat",
            path: "Sources/BLEChat"
        )
    ]
)

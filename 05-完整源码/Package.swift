// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PDDAXReader",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PDDAXReader", targets: ["PDDAXReader"])
    ],
    targets: [
        .executableTarget(name: "PDDAXReader"),
        .testTarget(name: "PDDAXReaderTests", dependencies: ["PDDAXReader"])
    ]
)

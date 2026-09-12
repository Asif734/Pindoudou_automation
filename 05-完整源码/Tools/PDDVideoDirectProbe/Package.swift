// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PDDVideoDirectProbe",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PDDVideoProbeCore", targets: ["PDDVideoProbeCore"]),
        .executable(name: "PDDVideoProbeApp", targets: ["PDDVideoProbeApp"])
    ],
    targets: [
        .target(name: "PDDVideoProbeCore"),
        .executableTarget(name: "PDDVideoProbeApp", dependencies: ["PDDVideoProbeCore"]),
        .testTarget(name: "PDDVideoProbeCoreTests", dependencies: ["PDDVideoProbeCore"])
    ]
)

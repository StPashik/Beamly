// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Beamly",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BeamlyCore", targets: ["BeamlyCore"]), .executable(name: "Beamly", targets: ["Beamly"])],
    targets: [
        .target(name: "BeamlyCore"),
        .executableTarget(name: "Beamly", dependencies: ["BeamlyCore"]),
        .testTarget(name: "BeamlyCoreTests", dependencies: ["BeamlyCore"]),
        .testTarget(name: "BeamlyAppTests", dependencies: ["Beamly", "BeamlyCore"])
    ],
    swiftLanguageModes: [.v5]
)

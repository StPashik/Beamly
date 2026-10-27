// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Beamly",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BeamlyCore", targets: ["BeamlyCore"]), .executable(name: "Beamly", targets: ["Beamly"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1")],
    targets: [
        .target(name: "BeamlyCore"),
        .executableTarget(name: "Beamly", dependencies: ["BeamlyCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "BeamlyCoreTests", dependencies: ["BeamlyCore"]),
        .testTarget(name: "BeamlyAppTests", dependencies: ["Beamly", "BeamlyCore"])
    ],
    swiftLanguageModes: [.v5]
)

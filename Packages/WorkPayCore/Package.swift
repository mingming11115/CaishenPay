// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WorkPayCore",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v13)],
    products: [.library(name: "WorkPayCore", targets: ["WorkPayCore"])],
    targets: [
        .target(name: "WorkPayCore"),
        .testTarget(name: "WorkPayCoreTests", dependencies: ["WorkPayCore"])
    ],
    swiftLanguageVersions: [.v5]
)

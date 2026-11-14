// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AtomHealthCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "AtomHealthCore", targets: ["AtomHealthCore"])],
    targets: [
        .target(name: "AtomHealthCore"),
        .testTarget(name: "AtomHealthCoreTests", dependencies: ["AtomHealthCore"], resources: [.copy("Resources")]),
    ]
)

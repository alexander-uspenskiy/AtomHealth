// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AtomHealthCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AtomHealthCore", targets: ["AtomHealthCore"]),
        .library(name: "AtomHealthKit", targets: ["AtomHealthKit"]),
    ],
    targets: [
        .target(name: "AtomHealthCore"),
        .target(name: "AtomHealthKit", dependencies: ["AtomHealthCore"]),
        .testTarget(name: "AtomHealthCoreTests", dependencies: ["AtomHealthCore"], resources: [.copy("Resources")]),
    ]
)

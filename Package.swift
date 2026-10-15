// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FWWIPCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FWWIPCore", targets: ["FWWIPCore"])],
    targets: [
        .target(name: "FWWIPCore", path: "fwwip", exclude: ["Assets.xcassets", "FWWIP.entitlements", "ContentView.swift", "FWWIP.swift"]),
        .testTarget(name: "FWWIPCoreTests", dependencies: ["FWWIPCore"])
    ]
)

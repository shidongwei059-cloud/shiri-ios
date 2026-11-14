// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShiriCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "ShiriCore", targets: ["ShiriCore"])],
    targets: [
        .target(name: "ShiriCore", path: "ShiriCore"),
        .testTarget(name: "ShiriCoreTests", dependencies: ["ShiriCore"], path: "ShiriTests")
    ]
)

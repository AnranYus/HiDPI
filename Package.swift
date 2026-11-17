// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "HiDPI",
    platforms: [.macOS(.v13)],
    targets: [
        // Objective-C bridge to the private virtual-display APIs
        // (SkyLight `SLVirtualDisplay*` on macOS 27+, CoreGraphics `CGVirtualDisplay*` before).
        // Classes are looked up at runtime, so nothing links against private frameworks.
        .target(
            name: "VirtualDisplayShim",
            cSettings: [.unsafeFlags(["-fobjc-arc"])]
        ),
        .executableTarget(
            name: "HiDPI",
            dependencies: ["VirtualDisplayShim"]
        ),
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Upscale",
    platforms: [.macOS(.v13)],
    products: [
        // The app target lives in App/Upscale.xcodeproj and consumes this library.
        .library(name: "UpscaleCore", targets: ["UpscaleCore"]),
    ],
    targets: [
        .target(
            name: "UpscaleCore",
            resources: [.copy("Resources/Shaders")]
        ),
        .testTarget(
            name: "UpscaleCoreTests",
            dependencies: ["UpscaleCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

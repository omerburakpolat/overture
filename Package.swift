// swift-tools-version: 6.2
// Overture module layout: one local SPM package, six library targets.
// (Spec 02 sketches six separate packages; a single package with six targets
// keeps the same import boundaries and testability with simpler wiring — the
// app target consumes these products, and `swift build`/`swift test` cover
// everything headlessly.)
import PackageDescription

let package = Package(
    name: "OverturePackages",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ProcessCore", targets: ["ProcessCore"]),
        .library(name: "ClaudeKit", targets: ["ClaudeKit"]),
        .library(name: "GitKit", targets: ["GitKit"]),
        .library(name: "VercelKit", targets: ["VercelKit"]),
        .library(name: "OvertureKit", targets: ["OvertureKit"]),
        .library(name: "OvertureDesign", targets: ["OvertureDesign"]),
    ],
    targets: [
        .target(name: "ProcessCore"),
        .target(name: "ClaudeKit", dependencies: ["ProcessCore"]),
        .target(name: "GitKit", dependencies: ["ProcessCore"]),
        .target(name: "VercelKit"),
        .target(name: "OvertureKit",
                dependencies: ["ClaudeKit", "GitKit", "VercelKit"]),
        .target(name: "OvertureDesign"),

        .testTarget(name: "ProcessCoreTests", dependencies: ["ProcessCore"]),
        .testTarget(name: "ClaudeKitTests", dependencies: ["ClaudeKit"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit"]),
        .testTarget(name: "VercelKitTests", dependencies: ["VercelKit"]),
        .testTarget(name: "OvertureKitTests", dependencies: ["OvertureKit"]),
        .testTarget(name: "OvertureDesignTests", dependencies: ["OvertureDesign"]),
    ],
    swiftLanguageModes: [.v6]
)

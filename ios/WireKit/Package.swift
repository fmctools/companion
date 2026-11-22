// swift-tools-version: 6.0
// The watch transport of FMC Companion, without UIKit: tested on the Mac with `swift test`.
// Frame, Session, Channel and Install come from WireKit of the workout iPhone app; vectors.json is shared with it,
// the Python host and the Android app.
import PackageDescription

let package = Package(
    name: "WireKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "WireKit", targets: ["WireKit"])],
    targets: [
        .target(name: "WireKit"),
        .testTarget(name: "WireKitTests", dependencies: ["WireKit"], resources: [.copy("vectors.json"), .copy("watchface-vectors.json"), .copy("rpc-vectors.json"), .copy("ota-vectors.json"), .copy("order-vectors.json"), .copy("push-vectors.json"), .copy("face-fit-vectors.json"), .copy("face-gate-vectors.json"), .copy("rescue-vectors.json")]),
    ]
)

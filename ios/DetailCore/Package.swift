// swift-tools-version:5.9
//
// DetailCore — pure business logic shared by the Detail CRM iPhone app.
// Foundation only (no SwiftUI/UIKit) so `swift test` runs on macOS and Linux.
import PackageDescription

let package = Package(
    name: "DetailCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "DetailCore", targets: ["DetailCore"]),
    ],
    targets: [
        .target(name: "DetailCore"),
        .testTarget(name: "DetailCoreTests", dependencies: ["DetailCore"]),
    ]
)

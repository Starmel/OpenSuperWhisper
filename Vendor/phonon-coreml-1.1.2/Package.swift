// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "phonon-coreml",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PhononCoreML", targets: ["PhononCoreML"]),
    ],
    targets: [
        .systemLibrary(name: "PhononTDT", path: "Sources/PhononTDT"),
        .target(
            name: "PhononCoreML",
            dependencies: ["PhononTDT"],
            path: "Sources/PhononCoreML",
            linkerSettings: [
                .unsafeFlags(["-L", "\(packageRoot)/Binaries"]),
            ]
        ),
    ]
)

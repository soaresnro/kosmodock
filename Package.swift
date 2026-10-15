// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kosmodock",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Kosmodock", targets: ["Kosmodock"]),
    ],
    targets: [
        .executableTarget(
            name: "Kosmodock",
            path: "Sources/Kosmodock",
            swiftSettings: [
                // UI types are explicitly @MainActor; v5 mode keeps AppKit/AX/Mach
                // interop free of strict-concurrency false positives.
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "KosmodockTests",
            dependencies: ["Kosmodock"],
            path: "Tests/KosmodockTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ai-clipboard",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AIClipboardCore", targets: ["AIClipboardCore"]),
        .executable(name: "AIClipboard", targets: ["AIClipboardApp"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .target(
            name: "AIClipboardCore",
            dependencies: ["CSQLite"],
            path: "Sources/AIClipboardCore",
            linkerSettings: [
                .linkedFramework("CryptoKit"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "AIClipboardApp",
            dependencies: ["AIClipboardCore"],
            path: "Sources/AIClipboardApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AuthenticationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("StoreKit")
            ]
        ),
        .testTarget(
            name: "AIClipboardCoreTests",
            dependencies: ["AIClipboardCore", "AIClipboardApp"],
            path: "Tests/AIClipboardCoreTests"
        )
    ]
)

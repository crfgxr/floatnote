// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FloatNote",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Vendored fork of SwiftTerm 1.13.0 (vendor/SwiftTerm, one patch commit
        // on top of upstream v1.13.0). The patch makes the terminal hold its
        // scroll position when the user scrolls up — upstream never sets the
        // Terminal.userScrolling flag its own auto-scroll logic checks — and
        // exposes linesBelowViewport / scrollToBottom() for the scroll-back
        // pill. Re-apply on upgrade: `git -C vendor/SwiftTerm log` has it.
        .package(path: "../vendor/SwiftTerm"),
    ],
    targets: [
        .executableTarget(
            name: "FloatNote",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "FloatNote",
            resources: [
                // Bundled Excalidraw web assets (vendored offline; see vendor/excalidraw).
                .copy("Resources/excalidraw"),
            ]
        ),
    ]
)

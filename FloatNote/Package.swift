// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FloatNote",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
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

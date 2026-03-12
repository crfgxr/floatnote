// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyEvernote",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MyEvernote",
            path: "MyEvernote"
        ),
    ]
)

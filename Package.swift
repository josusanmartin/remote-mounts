// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RemoteMounts",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "RemoteMounts", path: "Sources/RemoteMounts")
    ]
)

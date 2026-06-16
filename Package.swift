// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CodexQuota",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CodexQuota",
            path: "Sources/CodexQuota"
        )
    ]
)

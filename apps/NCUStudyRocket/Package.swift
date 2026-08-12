// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NCUStudyRocket",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NCUStudyRocket", targets: ["NCUStudyRocket"])],
    targets: [.executableTarget(name: "NCUStudyRocket")]
)

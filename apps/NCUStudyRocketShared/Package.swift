// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NCUStudyRocketShared",
    platforms: [
        .macOS(.v14),
        .iOS(.v26)
    ],
    products: [
        .library(name: "StudyRocketShared", targets: ["StudyRocketShared"])
    ],
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", from: "3.9.0")],
    targets: [
        .target(name: "StudyRocketShared", dependencies: [.product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "StudyRocketSharedChecks",
            dependencies: ["StudyRocketShared", .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))],
            path: "Tests/StudyRocketSharedChecks"
        )
    ]
)

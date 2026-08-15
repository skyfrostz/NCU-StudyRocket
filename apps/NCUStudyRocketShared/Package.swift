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
    targets: [
        .target(name: "StudyRocketShared"),
        .executableTarget(
            name: "StudyRocketSharedChecks",
            dependencies: ["StudyRocketShared"],
            path: "Tests/StudyRocketSharedChecks"
        )
    ]
)

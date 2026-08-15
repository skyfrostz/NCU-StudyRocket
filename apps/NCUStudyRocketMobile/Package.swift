// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NCUStudyRocketMobile",
    platforms: [
        .iOS(.v26),
        .macOS(.v14)
    ],
    products: [
        .library(name: "StudyRocketMobile", targets: ["StudyRocketMobile"])
    ],
    dependencies: [
        .package(path: "../NCUStudyRocketShared"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", exact: "2.4.1")
    ],
    targets: [
        .target(
            name: "StudyRocketMobile",
            dependencies: [
                .product(name: "StudyRocketShared", package: "NCUStudyRocketShared"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ]
        )
    ]
)

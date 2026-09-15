// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NCUStudyRocketMobile",
    platforms: [
        .iOS(.v26),
        .macOS(.v14)
    ],
    products: [
        .library(name: "StudyRocketMobile", targets: ["StudyRocketMobile"]),
        .library(name: "StudyRocketWidgetSupport", targets: ["StudyRocketWidgetSupport"])
    ],
    dependencies: [
        .package(path: "../NCUStudyRocketShared"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", exact: "2.4.1")
    ],
    targets: [
        .target(
            name: "StudyRocketMobile",
            dependencies: [
                "StudyRocketWidgetSupport",
                .product(name: "StudyRocketShared", package: "NCUStudyRocketShared"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ]
        ),
        .target(name: "StudyRocketWidgetSupport"),
        .testTarget(
            name: "StudyRocketMobileTests",
            dependencies: ["StudyRocketMobile"]
        )
    ]
)

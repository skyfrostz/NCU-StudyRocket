// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NCUStudyRocket",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NCUStudyRocket", targets: ["NCUStudyRocket"])],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", exact: "2.4.1")
    ],
    targets: [
        .executableTarget(
            name: "NCUStudyRocket",
            dependencies: [
                "StudyRocketChatCore",
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ]
        ),
        .target(
            name: "StudyRocketChatCore"
        ),
        .executableTarget(
            name: "NCUStudyRocketTests",
            dependencies: ["StudyRocketChatCore"],
            path: "Tests/NCUStudyRocketTests"
        )
    ]
)

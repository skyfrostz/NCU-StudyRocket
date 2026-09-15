// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NCUStudyRocket",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NCUStudyRocket", targets: ["NCUStudyRocket"]),
        .executable(name: "StudyRocketHost", targets: ["StudyRocketHost"])
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", exact: "2.4.1"),
        .package(url: "https://github.com/swiftlang/swift-cmark", exact: "0.8.0"),
        .package(path: "../NCUStudyRocketShared")
    ],
    targets: [
        .executableTarget(
            name: "NCUStudyRocket",
            dependencies: [
                "StudyRocketChatCore",
                "StudyRocketTimetableImport",
                .product(name: "StudyRocketShared", package: "NCUStudyRocketShared"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ]
        ),
        .executableTarget(
            name: "StudyRocketHost",
            dependencies: [
                "StudyRocketChatCore",
                .product(name: "StudyRocketShared", package: "NCUStudyRocketShared")
            ],
            path: "Sources/StudyRocketHost"
        ),
        .target(
            name: "StudyRocketChatCore",
            dependencies: [
                .product(name: "StudyRocketShared", package: "NCUStudyRocketShared"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark")
            ]
        ),
        .target(
            name: "StudyRocketTimetableImport",
            dependencies: [
                .product(name: "StudyRocketShared", package: "NCUStudyRocketShared")
            ],
            path: "Sources/StudyRocketTimetableImport"
        ),
        .executableTarget(
            name: "NCUStudyRocketTests",
            dependencies: ["StudyRocketChatCore"],
            path: "Tests/NCUStudyRocketTests"
        ),
        .executableTarget(
            name: "TimetableImportChecks",
            dependencies: ["StudyRocketTimetableImport"],
            path: "Tests/TimetableImportChecks"
        )
    ]
)

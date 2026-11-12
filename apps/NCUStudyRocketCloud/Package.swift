// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "NCUStudyRocketCloud", platforms: [.macOS(.v14)],
    products: [.executable(name: "StudyRocketCloud", targets: ["StudyRocketCloud"])],
    dependencies: [
        .package(path: "../NCUStudyRocketShared"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle", from: "2.13.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.9.0"),
        .package(url: "https://github.com/vapor/sqlite-nio.git", from: "1.9.0")
    ],
    targets: [.executableTarget(name: "StudyRocketCloud", dependencies: [
        .product(name: "StudyRocketShared", package: "NCUStudyRocketShared"),
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "SQLiteNIO", package: "sqlite-nio")
    ], swiftSettings: [.swiftLanguageMode(.v5)])]
)

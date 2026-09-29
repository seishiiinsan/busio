// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BusioKit",
    defaultLocalization: "fr",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "BusioKit", targets: ["BusioKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.33.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "BusioKit",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .testTarget(
            name: "BusioKitTests",
            dependencies: ["BusioKit"],
            exclude: ["Fixtures"]
        ),
    ]
)

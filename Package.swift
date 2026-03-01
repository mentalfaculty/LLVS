// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LLVS",
    platforms: [
        .macOS(.v15), .iOS(.v18), .watchOS(.v11)
    ],
    products: [
        .library(
            name: "SQLite3",
            targets: ["SQLite3"]),
        .library(
            name: "LLVS",
            targets: ["LLVS"]),
        .library(
            name: "LLVSCloudKit",
            targets: ["LLVSCloudKit"]),
        .library(
            name: "LLVSSQLite",
            targets: ["LLVSSQLite"]),
        .library(
            name: "LLVSPCloud",
            targets: ["LLVSPCloud"]),
        .library(
            name: "LLVSBox",
            targets: ["LLVSBox"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMajor(from: "0.9.0")),
        .package(url: "https://github.com/pCloud/pcloud-sdk-swift.git", from: "3.0.0"),
        .package(url: "https://github.com/box/box-ios-sdk.git", from: "10.0.0"),
    ],
    targets: [
        .systemLibrary(
            name: "SQLite3"
        ),
        .target(
            name: "LLVS",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "LLVSTests",
            dependencies: ["LLVS", "LLVSSQLite"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "LLVSCloudKit",
            dependencies: ["LLVS"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "LLVSSQLite",
            dependencies: ["LLVS", "SQLite3"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "LLVSPCloud",
            dependencies: [
                "LLVS",
                .product(name: "PCloudSDKSwift", package: "pcloud-sdk-swift")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "LLVSBox",
            dependencies: [
                "LLVS",
                .product(name: "BoxSDK", package: "box-ios-sdk")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)

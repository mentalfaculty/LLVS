// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LLVS",
    platforms: [
        .macOS(.v11), .iOS(.v14), .watchOS(.v7)
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
            name: "LLVSModel",
            targets: ["LLVSModel"]),
    ],
    dependencies: [
        .package(url: "https://github.com/drewmccormack/Forked.git", from: "0.5.9"),
    ],
    targets: [
        .systemLibrary(
            name: "SQLite3"
        ),
        .target(
            name: "LLVS",
            dependencies: [],
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
            name: "LLVSModel",
            dependencies: [
                "LLVS",
                .product(name: "ForkedModel", package: "Forked"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "LLVSModelTests",
            dependencies: [
                "LLVSModel",
                "LLVS",
                "LLVSSQLite",
                .product(name: "Forked", package: "Forked"),
                .product(name: "ForkedMerge", package: "Forked"),
                .product(name: "ForkedModel", package: "Forked"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)

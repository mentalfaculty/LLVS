// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LLVS",
    platforms: [
        .macOS(.v10_10), .iOS(.v10),
    ],
    products: [
        .library(
            name: "LLVS",
            targets: ["LLVS"]),
        .library(
            name: "LLVSCloudKit",
            targets: ["LLVSCloudKit"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "LLVS",
            dependencies: []),
        .testTarget(
            name: "LLVSTests",
            dependencies: ["LLVS"]),
        .target(
            name: "LLVSCloudKit",
            dependencies: ["LLVS"])
    ]
)

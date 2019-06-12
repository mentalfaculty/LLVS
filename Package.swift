// swift-tools-version:5.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LLVS",
    platforms: [
        .macOS(.v10_15), .iOS(.v13),
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

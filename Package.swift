// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LLVS",
    products: [
        .library(
            name: "LLVS",
            targets: ["LLVS"]),
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
    ],
    exclude: ["Samples"],
)

// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import CompilerPluginSupport

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
        .library(
            name: "LLVSModel",
            targets: ["LLVSModel"]),
        .library(
            name: "LLVSWebDAV",
            targets: ["LLVSWebDAV"]),
        .library(
            name: "LLVSGoogleDrive",
            targets: ["LLVSGoogleDrive"]),
        .library(
            name: "LLVSOneDrive",
            targets: ["LLVSOneDrive"]),
    ],
    // The LLVSBox and LLVSPCloud products are empty unless the consumer enables the matching trait,
    // e.g. .package(url: "...", from: "0.10.0", traits: ["Box"]). This keeps the vendor SDKs out of other apps.
    traits: [
        .trait(name: "Box", description: "Box backend via the Box SDK"),
        .trait(name: "PCloud", description: "pCloud backend via the pCloud SDK"),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMajor(from: "0.9.0")),
        .package(url: "https://github.com/pCloud/pcloud-sdk-swift.git", from: "3.0.0"),
        .package(url: "https://github.com/box/box-ios-sdk.git", from: "10.0.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
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
                .product(name: "PCloudSDKSwift", package: "pcloud-sdk-swift", condition: .when(traits: ["PCloud"]))
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "LLVSBox",
            dependencies: [
                "LLVS",
                .product(name: "BoxSDK", package: "box-ios-sdk", condition: .when(traits: ["Box"]))
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .macro(
            name: "LLVSModelMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]),
        .target(
            name: "LLVSModel",
            dependencies: [
                "LLVS",
                "LLVSModelMacros",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "LLVSWebDAV",
            dependencies: ["LLVS"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "LLVSGoogleDrive",
            dependencies: ["LLVS"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "LLVSOneDrive",
            dependencies: ["LLVS"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "LLVSModelTests",
            dependencies: [
                "LLVSModel",
                "LLVS",
                "LLVSSQLite",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)

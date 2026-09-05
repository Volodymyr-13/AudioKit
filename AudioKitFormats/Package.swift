// swift-tools-version: 5.9

import PackageDescription

// This is an independent extension package. The parent AudioKit package deliberately
// does not depend on this manifest or on any external codec.
let package = Package(
    name: "AudioKitFormats",
    platforms: [.macOS(.v11), .iOS(.v15), .tvOS(.v15)],
    products: [
        .library(name: "PCMDecoding", targets: ["PCMDecoding"]),
        .library(name: "FallbackDecoders", targets: ["FallbackDecoders"]),
        .library(name: "AudioKitFormats", targets: ["AudioKitFormats"]),
    ],
    dependencies: [
        .package(url: "https://github.com/AudioKit/AudioKit.git", from: "5.7.2"),
        .package(url: "https://github.com/sbooth/CXXMonkeysAudio", exact: "12.13.0"),
        .package(url: "https://github.com/sbooth/wavpack-binary-xcframework", exact: "0.2.0"),
    ],
    targets: [
        .target(name: "PCMDecoding"),
        .target(
            name: "CAPEDecoder",
            dependencies: [.product(name: "MAC", package: "CXXMonkeysAudio")],
            linkerSettings: [.linkedFramework("AVFAudio")]
        ),
        .target(
            name: "CWavPackDecoder",
            dependencies: [.product(name: "wavpack", package: "wavpack-binary-xcframework")],
            linkerSettings: [.linkedFramework("AVFAudio")]
        ),
        .target(name: "FallbackDecoders", dependencies: ["PCMDecoding", "CAPEDecoder", "CWavPackDecoder"]),
        .target(
            name: "AudioKitFormats",
            dependencies: ["PCMDecoding", .product(name: "AudioKit", package: "AudioKit")]
        ),
        .testTarget(
            name: "AudioKitFormatsTests",
            dependencies: ["AudioKitFormats", "FallbackDecoders"]
        ),
    ],
    cxxLanguageStandard: .cxx20
)

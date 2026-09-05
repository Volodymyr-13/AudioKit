// swift-tools-version: 5.9

import PackageDescription

// Private real-file integration suite. Kept separate so normal package tests
// remain self-contained and do not require private recordings.
let package = Package(
    name: "AudioKitFormatCorpus",
    platforms: [.macOS(.v11), .iOS(.v15)],
    dependencies: [
        .package(path: "../.."),
        .package(path: "../../.."),
    ],
    targets: [
        .testTarget(
            name: "FormatCorpusTests",
            dependencies: [
                .product(name: "AudioKit", package: "AudioKit"),
                .product(name: "AudioKitFormats", package: "AudioKitFormats"),
                .product(name: "FallbackDecoders", package: "AudioKitFormats"),
                .product(name: "PCMDecoding", package: "AudioKitFormats"),
            ],
            resources: [.copy("Corpus")]
        ),
    ]
)

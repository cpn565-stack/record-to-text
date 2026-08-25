// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "record-to-text",
    defaultLocalization: "zh-Hant",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "RecordToTextCore",
            targets: ["RecordToTextCore"]
        ),
        .executable(
            name: "record-to-text",
            targets: ["RecordToTextApp"]
        ),
        .executable(
            name: "record-to-text-self-test",
            targets: ["RecordToTextSelfTest"]
        ),
        .executable(
            name: "record-to-text-mock-helper",
            targets: ["RecordToTextMockHelper"]
        ),
        .executable(
            name: "record-to-text-pipeline-self-test",
            targets: ["RecordToTextPipelineSelfTest"]
        )
    ],
    targets: [
        .target(
            name: "RecordToTextCore",
            path: "Sources/RecordToTextCore"
        ),
        .executableTarget(
            name: "RecordToTextApp",
            dependencies: ["RecordToTextCore"],
            path: "Sources/RecordToTextApp",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "RecordToTextSelfTest",
            dependencies: ["RecordToTextCore"],
            path: "Tools/SelfTest"
        ),
        .executableTarget(
            name: "RecordToTextMockHelper",
            dependencies: ["RecordToTextCore"],
            path: "Tools/MockHelper"
        ),
        .executableTarget(
            name: "RecordToTextPipelineSelfTest",
            dependencies: ["RecordToTextCore"],
            path: "Tools/PipelineSelfTest"
        ),
        .testTarget(
            name: "RecordToTextCoreTests",
            dependencies: ["RecordToTextCore", "RecordToTextApp"],
            path: "Tests/RecordToTextCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)

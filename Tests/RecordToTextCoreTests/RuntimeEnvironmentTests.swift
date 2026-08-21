import Foundation
import XCTest
@testable import RecordToTextCore

final class RuntimeEnvironmentTests: XCTestCase {
    func testGoogleAIStudioResolvesBundledFFmpegWithoutDeveloperMode() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let bundled = try makeBundledAudioTools(in: root)

        let runtime = try RuntimeEnvironment.resolve(
            paths: paths,
            settings: AppSettings.defaultValue(developerMode: false),
            bundledHelperURL: nil,
            bundledFFmpegURL: bundled.ffmpeg,
            bundledFFprobeURL: bundled.ffprobe,
            includeSystemAudioTools: false
        )

        XCTAssertFalse(runtime.isDeveloperRuntime)
        XCTAssertEqual(runtime.ffmpeg.path, bundled.ffmpeg.path)
        XCTAssertEqual(runtime.ffprobe.path, bundled.ffprobe.path)
    }

    func testGoogleAIStudioPrefersBundledFFmpegOverReleaseBin() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        try createRuntimeFiles(at: paths)
        let bundled = try makeBundledAudioTools(in: root)

        let runtime = RuntimeEnvironment.candidate(
            paths: paths,
            settings: AppSettings.defaultValue(developerMode: false),
            bundledHelperURL: nil,
            bundledFFmpegURL: bundled.ffmpeg,
            bundledFFprobeURL: bundled.ffprobe,
            includeSystemAudioTools: false
        )

        XCTAssertEqual(runtime.ffmpeg.path, bundled.ffmpeg.path)
        XCTAssertEqual(runtime.ffprobe.path, bundled.ffprobe.path)
    }

    func testGoogleAIStudioFailsWhenFFmpegMissing() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)

        XCTAssertThrowsError(
            try RuntimeEnvironment.resolve(
                paths: paths,
                settings: AppSettings.defaultValue(developerMode: false),
                bundledHelperURL: nil,
                includeSystemAudioTools: false
            )
        ) { error in
            guard case let RuntimeEnvironmentError.missingComponents(components) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(
                Set(components.map(\.component)),
                [.ffmpeg, .ffprobe]
            )
        }
    }

    func testGoogleAIStudioInspectionIsReadyWhenAudioToolsExist() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bundled = try makeBundledAudioTools(in: root)
        let runtime = ResolvedRuntime(
            python: root.appendingPathComponent("python"),
            ffmpeg: bundled.ffmpeg,
            ffprobe: bundled.ffprobe,
            opencc: root.appendingPathComponent("opencc"),
            helper: root.appendingPathComponent(helperName),
            isDeveloperRuntime: false
        )

        let report = RuntimeEnvironment.inspect(
            runtime,
            backendType: .googleAIStudio
        )

        XCTAssertTrue(report.isReady)
        XCTAssertEqual(report.components.map(\.component), [.ffmpeg, .ffprobe])
        XCTAssertTrue(report.components.allSatisfy(\.isAvailable))
    }

    func testReleaseRuntimeFailsClosedWithoutVerifierWhenNotCloud() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        try createRuntimeFiles(at: paths)

        // Cloud backends skip the old MLX verifier. This documents the remaining
        // fail-closed path if a future local backend is reintroduced.
        let settings = AppSettings.defaultValue(developerMode: false)
        XCTAssertEqual(settings.backendType, .googleAIStudio)

        let runtime = try RuntimeEnvironment.resolve(
            paths: paths,
            settings: settings,
            bundledHelperURL: nil,
            includeSystemAudioTools: false
        )
        XCTAssertFalse(runtime.isDeveloperRuntime)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: runtime.ffmpeg.path))
    }

    func testTextFileValidatorRejectsBlankAndInvalidUTF8() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let blank = root.appendingPathComponent("blank.txt")
        let invalid = root.appendingPathComponent("invalid.txt")
        try Data(" \n\t".utf8).write(to: blank)
        try Data([0xC3, 0x28]).write(to: invalid)

        XCTAssertThrowsError(try TextFileValidator.readNonEmptyUTF8(at: blank)) {
            guard case TextFileValidationError.empty = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
        XCTAssertThrowsError(try TextFileValidator.readNonEmptyUTF8(at: invalid)) {
            guard case TextFileValidationError.invalidUTF8 = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }

    private func makeBundledAudioTools(in root: URL) throws -> (ffmpeg: URL, ffprobe: URL) {
        let helpers = root.appendingPathComponent("Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let ffmpeg = helpers.appendingPathComponent("ffmpeg")
        let ffprobe = helpers.appendingPathComponent("ffprobe")
        for url in [ffmpeg, ffprobe] {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path
            )
        }
        return (ffmpeg, ffprobe)
    }

    private func createRuntimeFiles(at paths: ApplicationPaths) throws {
        let bin = runtimeBin(paths)
        try FileManager.default.createDirectory(
            at: bin,
            withIntermediateDirectories: true
        )

        for name in ["python", "ffmpeg", "ffprobe", "opencc", helperName] {
            let url = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path
            )
        }
    }

    private var helperName: String {
        CPUArchitecture.current == .x86_64
            ? "qwen_asr_transformers_runner.py"
            : "qwen_asr_mlx_runner.py"
    }

    private func runtimeBin(_ paths: ApplicationPaths) -> URL {
        paths.runtimes
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }
}

import Foundation
import XCTest
@testable import RecordToTextCore

final class RuntimeEnvironmentTests: XCTestCase {
    func testReleaseRuntimeFailsClosedWithoutVerifier() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        try createRuntimeFiles(at: paths)

        XCTAssertThrowsError(
            try RuntimeEnvironment.resolve(
                paths: paths,
                settings: AppSettings.defaultValue(developerMode: false),
                bundledHelperURL: nil
            )
        ) { error in
            guard case RuntimeEnvironmentError.releaseRuntimeNotVerified = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testReleaseRuntimeVerifierUnlocksResolvedRuntime() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        try createRuntimeFiles(at: paths)
        var verifierWasCalled = false

        let runtime = try RuntimeEnvironment.resolve(
            paths: paths,
            settings: AppSettings.defaultValue(developerMode: false),
            bundledHelperURL: nil,
            releaseRuntimeVerifier: { _ in
                verifierWasCalled = true
            }
        )

        XCTAssertTrue(verifierWasCalled)
        XCTAssertFalse(runtime.isDeveloperRuntime)
    }

    func testReleaseRuntimeInspectionDoesNotClaimReadyBeforeVerification() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        try createRuntimeFiles(at: paths)
        let runtime = ResolvedRuntime(
            python: runtimeBin(paths).appendingPathComponent("python"),
            ffmpeg: runtimeBin(paths).appendingPathComponent("ffmpeg"),
            ffprobe: runtimeBin(paths).appendingPathComponent("ffprobe"),
            opencc: runtimeBin(paths).appendingPathComponent("opencc"),
            helper: runtimeBin(paths).appendingPathComponent(helperName),
            isDeveloperRuntime: false
        )

        let unverified = RuntimeEnvironment.inspect(runtime)
        let verified = RuntimeEnvironment.inspect(
            runtime,
            releaseRuntimeVerified: true
        )

        XCTAssertFalse(unverified.isReady)
        XCTAssertTrue(
            unverified.components.allSatisfy {
                $0.detail.contains("尚未通過驗證")
            }
        )
        XCTAssertTrue(verified.isReady)
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

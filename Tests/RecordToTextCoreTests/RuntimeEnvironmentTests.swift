import Foundation
import XCTest
@testable import RecordToTextCore

final class RuntimeEnvironmentTests: XCTestCase {
    func testGoogleAIStudioResolvesBundledFFmpegWithoutDeveloperMode() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let bundled = try makeBundledAudioTools(in: root)
        let cloudDiscovery = try makeCloudDiscovery(in: root)

        let runtime = try RuntimeEnvironment.resolve(
            paths: paths,
            settings: AppSettings.defaultValue(developerMode: false),
            bundledHelperURL: nil,
            bundledFFmpegURL: bundled.ffmpeg,
            bundledFFprobeURL: bundled.ffprobe,
            includeSystemAudioTools: false,
            developerRuntimeDiscovery: cloudDiscovery
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
        let cloudDiscovery = try makeCloudDiscovery(in: root)

        let runtime = RuntimeEnvironment.candidate(
            paths: paths,
            settings: AppSettings.defaultValue(developerMode: false),
            bundledHelperURL: nil,
            bundledFFmpegURL: bundled.ffmpeg,
            bundledFFprobeURL: bundled.ffprobe,
            includeSystemAudioTools: false,
            developerRuntimeDiscovery: cloudDiscovery
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
            let missingComponents = Set(components.map(\.component))
            XCTAssertTrue(missingComponents.contains(.ffmpeg))
            XCTAssertTrue(missingComponents.contains(.ffprobe))
        }
    }

    func testGoogleAIStudioInspectionIsReadyWhenAudioToolsExist() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bundled = try makeBundledAudioTools(in: root)
        let openCC = root.appendingPathComponent("opencc")
        try makeExecutable(at: openCC)
        let runtime = ResolvedRuntime(
            python: root.appendingPathComponent("python"),
            ffmpeg: bundled.ffmpeg,
            ffprobe: bundled.ffprobe,
            opencc: openCC,
            helper: root.appendingPathComponent(helperName),
            isDeveloperRuntime: false
        )

        let report = RuntimeEnvironment.inspect(
            runtime,
            backendType: .googleAIStudio
        )

        XCTAssertTrue(report.isReady)
        XCTAssertEqual(
            report.components.map(\.component),
            [.ffmpeg, .ffprobe, .opencc]
        )
        XCTAssertTrue(report.components.allSatisfy(\.isAvailable))
    }

    func testCloudBackendManagedAudioFallbackFailsClosedWithoutVerifier() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        try createRuntimeFiles(at: paths)

        let settings = AppSettings.defaultValue(developerMode: false)
        XCTAssertEqual(settings.backendType, .googleAIStudio)

        XCTAssertThrowsError(
            try RuntimeEnvironment.resolve(
                paths: paths,
                settings: settings,
                bundledHelperURL: nil,
                includeSystemAudioTools: false
            )
        ) { error in
            guard case RuntimeEnvironmentError.releaseRuntimeNotVerified = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCloudBackendManagedAudioFallbackRequiresAndUsesVerifier() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        try createRuntimeFiles(at: paths)
        var verifierCalled = false

        let runtime = try RuntimeEnvironment.resolve(
            paths: paths,
            settings: AppSettings.defaultValue(developerMode: false),
            bundledHelperURL: nil,
            includeSystemAudioTools: false,
            releaseRuntimeVerifier: { resolved in
                verifierCalled = true
                XCTAssertTrue(resolved.managedComponents.contains(.ffmpeg))
                XCTAssertTrue(resolved.managedComponents.contains(.ffprobe))
                // Cloud OpenCC is developer-discovered, not a managed component.
            }
        )

        XCTAssertTrue(verifierCalled)
        XCTAssertEqual(
            runtime.managedComponents.intersection([.ffmpeg, .ffprobe]),
            [.ffmpeg, .ffprobe]
        )
    }

    func testManagedLocalRuntimeFailsClosedWithoutVerifier() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        try createRuntimeFiles(at: paths)

        XCTAssertThrowsError(
            try RuntimeEnvironment.resolve(
                paths: paths,
                settings: localSettings(developerMode: false),
                bundledHelperURL: nil,
                includeSystemAudioTools: false
            )
        ) { error in
            guard case RuntimeEnvironmentError.releaseRuntimeNotVerified = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(
                error.localizedDescription.contains("拒絕執行"),
                "The user-facing error must explain that execution was denied."
            )
        }
    }

    func testManagedLocalRuntimeVerifierUnlocksRuntime() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        try createRuntimeFiles(at: paths)
        var verifiedRuntime: ResolvedRuntime?

        let runtime = try RuntimeEnvironment.resolve(
            paths: paths,
            settings: localSettings(developerMode: false),
            bundledHelperURL: nil,
            includeSystemAudioTools: false,
            releaseRuntimeVerifier: { verifiedRuntime = $0 }
        )

        XCTAssertEqual(verifiedRuntime, runtime)
        XCTAssertFalse(runtime.isDeveloperRuntime)
    }

    func testManagedLocalRuntimeVerifierFailureHasClearError() throws {
        struct VerificationFailure: LocalizedError {
            var errorDescription: String? { "簽章不符" }
        }

        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        try createRuntimeFiles(at: paths)

        XCTAssertThrowsError(
            try RuntimeEnvironment.resolve(
                paths: paths,
                settings: localSettings(developerMode: false),
                bundledHelperURL: nil,
                includeSystemAudioTools: false,
                releaseRuntimeVerifier: { _ in throw VerificationFailure() }
            )
        ) { error in
            guard case let RuntimeEnvironmentError.releaseRuntimeVerificationFailed(reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(reason, "簽章不符")
            XCTAssertTrue(error.localizedDescription.contains("拒絕執行"))
        }
    }

    func testManagedLocalInspectionDoesNotClaimReadyBeforeVerification() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        try createRuntimeFiles(at: paths)
        let runtime = RuntimeEnvironment.candidate(
            paths: paths,
            settings: localSettings(developerMode: false),
            bundledHelperURL: nil,
            includeSystemAudioTools: false
        )

        let unverified = RuntimeEnvironment.inspect(
            runtime,
            backendType: .localQwen
        )
        let verified = RuntimeEnvironment.inspect(
            runtime,
            backendType: .localQwen,
            releaseRuntimeVerified: true
        )

        XCTAssertFalse(unverified.isReady)
        XCTAssertEqual(
            Set(unverified.components.map(\.component)),
            [.python, .ffmpeg, .ffprobe, .opencc, .helper]
        )
        XCTAssertTrue(
            unverified.components.allSatisfy {
                !$0.isAvailable && $0.detail.contains("尚未通過完整性驗證")
            }
        )
        XCTAssertTrue(verified.isReady)
    }

    func testDeveloperRuntimeUsesExplicitPathsWithoutReleaseVerifier() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let bundled = try makeBundledAudioTools(in: root)
        let python = root.appendingPathComponent("developer/python")
        let openCC = root.appendingPathComponent("developer/opencc")
        let helper = root.appendingPathComponent("developer/helper.py")
        try makeExecutable(at: python)
        try makeExecutable(at: openCC)
        try makeExecutable(at: helper)

        var settings = localSettings(developerMode: true)
        settings.customPythonPath = "  \(python.path)  "
        settings.customHelperPath = "\n\(helper.path)\t"
        let discovery = DeveloperRuntimeDiscovery(
            python: root.appendingPathComponent("unused-python"),
            openCC: openCC,
            pythonWasDetected: false,
            openCCWasDetected: true
        )

        let runtime = try RuntimeEnvironment.resolve(
            paths: paths,
            settings: settings,
            bundledHelperURL: nil,
            bundledFFmpegURL: bundled.ffmpeg,
            bundledFFprobeURL: bundled.ffprobe,
            includeSystemAudioTools: false,
            developerRuntimeDiscovery: discovery
        )

        XCTAssertTrue(runtime.isDeveloperRuntime)
        XCTAssertEqual(runtime.python.path, python.path)
        XCTAssertEqual(runtime.opencc.path, openCC.path)
        XCTAssertEqual(runtime.helper.path, helper.path)
        XCTAssertTrue(
            RuntimeEnvironment.inspect(runtime, backendType: .localQwen).isReady
        )
    }

    func testDeveloperRuntimeDoesNotTrustManagedHelperFallback() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        try createRuntimeFiles(at: paths)
        let bundled = try makeBundledAudioTools(in: root)
        let python = root.appendingPathComponent("developer/python")
        let openCC = root.appendingPathComponent("developer/opencc")
        try makeExecutable(at: python)
        try makeExecutable(at: openCC)
        let discovery = DeveloperRuntimeDiscovery(
            python: python,
            openCC: openCC,
            pythonWasDetected: true,
            openCCWasDetected: true
        )

        XCTAssertThrowsError(
            try RuntimeEnvironment.resolve(
                paths: paths,
                settings: localSettings(developerMode: true),
                bundledHelperURL: nil,
                bundledFFmpegURL: bundled.ffmpeg,
                bundledFFprobeURL: bundled.ffprobe,
                includeSystemAudioTools: false,
                developerRuntimeDiscovery: discovery
            )
        ) { error in
            guard case RuntimeEnvironmentError.releaseRuntimeNotVerified = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testDeveloperRuntimeDiscoveryFindsDedicatedPythonAndOpenCCOnPATH() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let environmentName = CPUArchitecture.current == .x86_64
            ? "record-to-text-intel-env"
            : "mlx-audio-env"
        let python = root
            .appendingPathComponent(environmentName, isDirectory: true)
            .appendingPathComponent("bin/python")
        let pathBin = root.appendingPathComponent("tools", isDirectory: true)
        let openCC = pathBin.appendingPathComponent("opencc")
        try makeExecutable(at: python)
        try makeExecutable(at: openCC)

        let discovery = RuntimeEnvironment.discoverDeveloperRuntime(
            homeDirectory: root,
            environment: ["PATH": pathBin.path],
            includeStandardOpenCCLocations: false
        )

        XCTAssertEqual(discovery.python.path, python.path)
        XCTAssertEqual(discovery.openCC.path, openCC.path)
        XCTAssertTrue(discovery.pythonWasDetected)
        XCTAssertTrue(discovery.openCCWasDetected)
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

    private func makeCloudDiscovery(
        in root: URL
    ) throws -> DeveloperRuntimeDiscovery {
        let openCC = root.appendingPathComponent("cloud-tools/opencc")
        try makeExecutable(at: openCC)
        return DeveloperRuntimeDiscovery(
            python: root.appendingPathComponent("unused-python"),
            openCC: openCC,
            pythonWasDetected: false,
            openCCWasDetected: true
        )
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

    private func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func localSettings(developerMode: Bool) -> AppSettings {
        var settings = AppSettings.defaultValue(developerMode: developerMode)
        settings.backendType = .localQwen
        return settings
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

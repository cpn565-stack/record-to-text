import Foundation
import XCTest
@testable import RecordToTextCore

final class HelperBytecodeTests: XCTestCase {
    func testBothHelperLaunchModesLeaveImportedResourcesUnchanged() async throws {
        let python = ["/opt/homebrew/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let python else { throw XCTSkip("Python required for import regression") }
        for name in ["qwen_asr_mlx_runner.py", "qwen_asr_transformers_runner.py"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let helper = root.appendingPathComponent(name)
            try "value = '測試逐字稿'\n".write(
                to: root.appendingPathComponent("imported_resource.py"), atomically: true, encoding: .utf8)
            try #"""
            import json, sys
            from pathlib import Path
            import imported_resource
            def complete(request):
                Path(request['outputPath']).write_text(imported_resource.value)
                print(json.dumps({'type': 'completed', 'outputPath': request['outputPath']}), flush=True)
            if '--server' in sys.argv:
                for line in sys.stdin:
                    complete(json.loads(line))
            else:
                complete(json.loads(Path(sys.argv[sys.argv.index('--request-json') + 1]).read_text()))
            """#.write(to: helper, atomically: true, encoding: .utf8)
            let executable = URL(fileURLWithPath: python)
            let backend = HelperASRBackend(
                runtime: ResolvedRuntime(python: executable, ffmpeg: executable, ffprobe: executable,
                                         opencc: executable, helper: helper, isDeveloperRuntime: true),
                paths: ApplicationPaths(root: root), runner: ProcessRunner())
            let request = ASRRequest(jobID: "bytecode", audioPath: root.appendingPathComponent("audio.wav").path,
                                     outputPath: root.appendingPathComponent("output.txt").path,
                                     modelID: "test", language: "zh", prompt: "", terms: [],
                                     modelCacheDirectory: root.path, offline: true)
            _ = try await backend.transcribe(request: request,
                                            requestURL: root.appendingPathComponent("request.json"),
                                            eventHandler: { _ in })
            backend.cancelCurrentJob()
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("__pycache__").path), name)
        }
    }
}

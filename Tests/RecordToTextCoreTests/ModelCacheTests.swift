import Foundation
import XCTest
@testable import RecordToTextCore

final class ModelCacheTests: XCTestCase {
    func testRepositoryFolderNameEscapesSlash() {
        XCTAssertEqual(
            ModelCache.repositoryFolderName(modelID: "mlx-community/Qwen3-ASR-1.7B-bf16"),
            "models--mlx-community--Qwen3-ASR-1.7B-bf16"
        )
    }

    func testIsDownloadedDetectsUsableSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-to-text-model-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let models = root.appendingPathComponent("Models", isDirectory: true)
        let revision = "e1f6c266914abc5a46e8756e02580f834a6cf8a7"
        let modelID = "mlx-community/Qwen3-ASR-1.7B-bf16"
        let snapshot = ModelCache.hubRoot(modelsDirectory: models)
            .appendingPathComponent(
                ModelCache.repositoryFolderName(modelID: modelID),
                isDirectory: true
            )
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)

        try FileManager.default.createDirectory(
            at: snapshot,
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(
            to: snapshot.appendingPathComponent("config.json")
        )
        try Data("weights".utf8).write(
            to: snapshot.appendingPathComponent("model.safetensors")
        )

        XCTAssertTrue(
            ModelCache.isDownloaded(
                modelID: modelID,
                revision: revision,
                modelsDirectory: models
            )
        )
        XCTAssertFalse(
            ModelCache.isDownloaded(
                modelID: modelID,
                revision: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
                modelsDirectory: models
            )
        )
    }

    func testUnusableSnapshotWithoutWeightsIsRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-to-text-model-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let models = root.appendingPathComponent("Models", isDirectory: true)
        let revision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let modelID = "mlx-community/Qwen3-ASR-1.7B-8bit"
        let snapshot = ModelCache.hubRoot(modelsDirectory: models)
            .appendingPathComponent(
                ModelCache.repositoryFolderName(modelID: modelID),
                isDirectory: true
            )
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)

        try FileManager.default.createDirectory(
            at: snapshot,
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(
            to: snapshot.appendingPathComponent("config.json")
        )

        XCTAssertFalse(
            ModelCache.isDownloaded(
                modelID: modelID,
                revision: revision,
                modelsDirectory: models
            )
        )
    }
}

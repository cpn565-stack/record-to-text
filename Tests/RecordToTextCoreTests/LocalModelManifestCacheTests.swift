import Foundation
import XCTest
@testable import RecordToTextCore

final class LocalModelManifestCacheTests: XCTestCase {
    private var root: URL!
    private let modelID = "mlx-community/Qwen3-ASR-1.7B-bf16"
    private let revision = "e1f6c266914abc5a46e8756e02580f834a6cf8a7"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-manifest-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func fixture() throws -> (hub: URL, snapshot: URL, blob: URL) {
        let hub = ModelCache.hubRoot(modelsDirectory: root.appendingPathComponent("Models"))
        let repository = ModelCache.repositoryDirectory(modelID: modelID, hubRoot: hub)
        let snapshot = repository.appendingPathComponent("snapshots/\(revision)")
        let blobs = repository.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let blob = blobs.appendingPathComponent("weights")
        try Data("weights-a".utf8).write(to: blob)
        try FileManager.default.createSymbolicLink(
            atPath: snapshot.appendingPathComponent("model.safetensors").path,
            withDestinationPath: "../../blobs/weights"
        )
        // Keep a regular metadata file: previously the manifest silently included
        // it while omitting the linked weights, producing a misleading identity.
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        return (hub, snapshot, blob)
    }

    func testManifestIncludesLinkedWeightsAndDetectsSameSizeBlobMutation() async throws {
        let f = try fixture()
        let first = try await LocalModelManifestStore.compute(
            modelID: modelID, revision: revision, cacheDirectory: f.hub
        )
        XCTAssertEqual(first.fileCount, 2)
        let weights = try XCTUnwrap(first.files.first { $0.relativePath == "model.safetensors" })
        XCTAssertTrue(weights.isSymbolicLink)
        XCTAssertEqual(weights.byteCount, 9)
        XCTAssertEqual(weights.sha256, LocalDigest.sha256(Data("weights-a".utf8)))
        XCTAssertEqual(first.totalByteCount, 11)

        try Data("weights-b".utf8).write(to: f.blob)
        let second = try await LocalModelManifestStore.compute(
            modelID: modelID, revision: revision, cacheDirectory: f.hub
        )
        XCTAssertNotEqual(first.digest, second.digest)
        XCTAssertEqual(first.totalByteCount, second.totalByteCount)
    }

    func testBrokenWeightLinkCannotProduceAMetadataOnlyManifest() async throws {
        let f = try fixture()
        try FileManager.default.removeItem(at: f.blob)
        do {
            _ = try await LocalModelManifestStore.compute(
                modelID: modelID, revision: revision, cacheDirectory: f.hub
            )
            XCTFail("A missing weight target must reject the manifest, not omit the link")
        } catch {
            // A filesystem error is expected; the engine can then disable reuse.
        }
    }
}

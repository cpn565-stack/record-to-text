import Foundation
import XCTest
@testable import RecordToTextCore

final class LocalChunkCheckpointTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "local-chunk-checkpoint-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSecureDirectoryAndUsableCheckpointDetection() throws {
        let checkpointDirectory = try LocalChunkCheckpoint.createSecureDirectory(
            in: root
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: checkpointDirectory.path
        )
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions.map { $0 & 0o777 }, 0o700)

        let checkpoint = checkpointDirectory.appendingPathComponent(
            "segment-0001-of-0001.chunks.json"
        )
        try Data(
            """
            {
              "schemaVersion": 1,
              "fingerprint": "\(String(repeating: "a", count: 64))",
              "totalChunks": 2,
              "completedChunks": [
                {"index": 0, "text": "已完成。", "containsSkippedAudio": false}
              ]
            }
            """.utf8
        ).write(to: checkpoint)

        XCTAssertTrue(LocalChunkCheckpoint.containsUsableCheckpoint(in: root))
    }

    func testRejectsEmptyMalformedAndNonContiguousCheckpoints() throws {
        let directory = try LocalChunkCheckpoint.createSecureDirectory(in: root)
        try Data("{}".utf8).write(
            to: directory.appendingPathComponent("broken.chunks.json")
        )
        XCTAssertFalse(LocalChunkCheckpoint.containsUsableCheckpoint(in: root))

        try Data(
            """
            {
              "schemaVersion": 1,
              "fingerprint": "\(String(repeating: "b", count: 64))",
              "totalChunks": 2,
              "completedChunks": [
                {"index": 1, "text": "不連續。", "containsSkippedAudio": false}
              ]
            }
            """.utf8
        ).write(to: directory.appendingPathComponent("invalid.chunks.json"))
        XCTAssertFalse(LocalChunkCheckpoint.containsUsableCheckpoint(in: root))
    }
}

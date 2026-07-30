import Foundation
import XCTest
@testable import RecordToTextCore

final class PersistenceTests: XCTestCase {
    private struct SampleRecord: Codable, Equatable {
        let schemaVersion: Int
        let name: String
        let updatedAt: Date
    }

    func testAtomicWriteTextNormalizesLineEndingsAndRemovesLeadingBOM() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("結果.txt")

        try AtomicFileWriter.writeText(
            "\u{FEFF}第一行\r\n第二行\r第三行\n",
            to: destination
        )

        let data = try Data(contentsOf: destination)
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            "第一行\n第二行\n第三行\n"
        )
        XCTAssertFalse(data.starts(with: [0xEF, 0xBB, 0xBF]))
        XCTAssertFalse(data.contains(0x0D))
    }

    func testAtomicWriteCreatesParentDirectoriesAndReplacesExistingFile() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let destination = directory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("result.txt")

        try AtomicFileWriter.writeText("舊內容", to: destination)
        try AtomicFileWriter.writeText("新內容", to: destination)

        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            "新內容"
        )
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: destination.deletingLastPathComponent().path
        )
        XCTAssertEqual(siblings, ["result.txt"])
    }

    func testAtomicWriteSupportsEmptyData() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("empty.bin")

        try AtomicFileWriter.write(Data(), to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data())
    }

    func testAtomicWriteNewNeverReplacesExistingDestination() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.txt")
        try AtomicFileWriter.writeText("原有內容", to: destination)

        XCTAssertThrowsError(
            try AtomicFileWriter.writeTextNew("不可覆寫", to: destination)
        ) { error in
            guard case AtomicFileWriterError.destinationExists = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            "原有內容"
        )
    }

    func testJSONRepositoryReturnsDefaultWithoutCreatingAFile() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("record.json")
        let repository = JSONRepository<SampleRecord>(url: url)
        let fallback = SampleRecord(
            schemaVersion: 1,
            name: "預設",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(try repository.load(default: fallback), fallback)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testJSONRepositoryRoundTripsAndAtomicallyOverwritesCodableValue() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("record.json")
        let repository = JSONRepository<SampleRecord>(url: url)
        let first = SampleRecord(
            schemaVersion: 1,
            name: "第一次",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let second = SampleRecord(
            schemaVersion: 2,
            name: "第二次／更新",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        try repository.save(first)
        XCTAssertEqual(try repository.load(default: first), first)

        try repository.save(second)
        XCTAssertEqual(try repository.load(default: first), second)

        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(siblings, ["record.json"])
    }

    func testJSONRepositoryRejectsCorruptJSON() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("record.json")
        try Data(#"{"schemaVersion":"wrong type"}"#.utf8).write(to: url)
        let repository = JSONRepository<SampleRecord>(url: url)
        let fallback = SampleRecord(
            schemaVersion: 1,
            name: "fallback",
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertThrowsError(try repository.load(default: fallback))
    }

    func testApplicationPathsCreateExpectedDirectoryLayout() throws {
        let temporaryRoot = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: temporaryRoot) }
        let root = temporaryRoot.appendingPathComponent("support", isDirectory: true)
        let paths = ApplicationPaths(root: root)

        try paths.createDirectories()

        for directory in [
            paths.root,
            paths.models,
            paths.runtimes,
            paths.logs,
            paths.tempRecovery
        ] {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: directory.path,
                    isDirectory: &isDirectory
                )
            )
            XCTAssertTrue(isDirectory.boolValue)
        }
        XCTAssertEqual(paths.settings.lastPathComponent, "settings.json")
        XCTAssertEqual(paths.glossaries.lastPathComponent, "glossaries.json")
        XCTAssertEqual(paths.recentJobs.lastPathComponent, "recent-jobs.json")
    }
}

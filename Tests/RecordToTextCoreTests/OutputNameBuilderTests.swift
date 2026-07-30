import Foundation
import XCTest
@testable import RecordToTextCore

final class OutputNameBuilderTests: XCTestCase {
    func testDefaultNamePreservesChineseSpacesAndAdditionalDots() {
        let source = URL(fileURLWithPath: "/tmp/客戶 會議.v2.m4a")
        let output = OutputNameBuilder.availableOutputURL(
            sourceURL: source,
            directory: URL(fileURLWithPath: "/tmp/output", isDirectory: true),
            fileExists: { _ in false }
        )

        XCTAssertEqual(output.lastPathComponent, "客戶 會議.v2_逐字稿.txt")
    }

    func testAvailableNameIncrementsWithoutOverwritingExistingNames() {
        let directory = URL(fileURLWithPath: "/tmp/output", isDirectory: true)
        let source = URL(fileURLWithPath: "/tmp/訪談.m4a")
        let occupied = Set([
            directory.appendingPathComponent("訪談_逐字稿.txt").path,
            directory.appendingPathComponent("訪談_逐字稿_2.txt").path
        ])

        let output = OutputNameBuilder.availableOutputURL(
            sourceURL: source,
            directory: directory,
            fileExists: { occupied.contains($0) }
        )

        XCTAssertEqual(output.lastPathComponent, "訪談_逐字稿_3.txt")
    }

    func testSanitizedStemRemovesControlCharactersAndColonThenTrims() {
        let source = URL(
            fileURLWithPath: "/tmp/ 會議:\u{0001}錄音 .m4a"
        )

        XCTAssertEqual(
            OutputNameBuilder.sanitizedStem(for: source),
            "會議錄音"
        )
    }

    func testSanitizedStemFallsBackWhenNoSafeCharactersRemain() {
        let source = URL(fileURLWithPath: "/tmp/:.m4a")

        XCTAssertEqual(
            OutputNameBuilder.sanitizedStem(for: source),
            "轉錄結果"
        )
    }

    func testRawTranscriptUsesRawSuffixAndCollisionIncrement() {
        let directory = URL(fileURLWithPath: "/tmp/output", isDirectory: true)
        let source = URL(fileURLWithPath: "/tmp/訪談.mp3")
        let firstPath = directory.appendingPathComponent("訪談_Qwen原始.txt").path

        let output = OutputNameBuilder.rawTranscriptURL(
            sourceURL: source,
            directory: directory,
            fileExists: { $0 == firstPath }
        )

        XCTAssertEqual(output.lastPathComponent, "訪談_Qwen原始_2.txt")
    }

    func testCustomSuffixAndPreview() {
        let source = URL(fileURLWithPath: "/tmp/訪談.m4a")
        let output = OutputNameBuilder.availableOutputURL(
            sourceURL: source,
            directory: URL(fileURLWithPath: "/tmp/output", isDirectory: true),
            suffix: "_逐字稿",
            fileExists: { _ in false }
        )

        XCTAssertEqual(output.lastPathComponent, "訪談_逐字稿.txt")
        XCTAssertEqual(
            OutputNameBuilder.previewFileName(suffix: "_會議紀錄"),
            "原檔名_會議紀錄.txt"
        )
        XCTAssertEqual(
            OutputNameBuilder.sanitizedSuffix("  a/b:c  ", fallback: "_逐字稿"),
            "abc"
        )
        XCTAssertEqual(
            OutputNameBuilder.sanitizedSuffix("   ", fallback: "_逐字稿"),
            "_逐字稿"
        )
    }

    func testJobSnapshotDecodesMissingFilenameSuffixWithDefaults() throws {
        let json = """
        {
          "modelID": "mock/model",
          "language": "Chinese",
          "glossaryID": null,
          "glossaryName": null,
          "terms": [],
          "prompt": "忠實轉錄",
          "outputLocationMode": "fixedDirectory",
          "outputDirectory": "/tmp/output",
          "keepRawTranscript": false
        }
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: json)
        XCTAssertEqual(snapshot.outputFilenameSuffix, "_逐字稿")
        XCTAssertEqual(snapshot.rawFilenameSuffix, "_Qwen原始")
    }
}

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

        XCTAssertEqual(output.lastPathComponent, "客戶 會議.v2_繁體.txt")
    }

    func testAvailableNameIncrementsWithoutOverwritingExistingNames() {
        let directory = URL(fileURLWithPath: "/tmp/output", isDirectory: true)
        let source = URL(fileURLWithPath: "/tmp/訪談.m4a")
        let occupied = Set([
            directory.appendingPathComponent("訪談_繁體.txt").path,
            directory.appendingPathComponent("訪談_繁體_2.txt").path
        ])

        let output = OutputNameBuilder.availableOutputURL(
            sourceURL: source,
            directory: directory,
            fileExists: { occupied.contains($0) }
        )

        XCTAssertEqual(output.lastPathComponent, "訪談_繁體_3.txt")
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
}

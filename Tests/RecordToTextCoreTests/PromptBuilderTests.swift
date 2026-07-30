import XCTest
@testable import RecordToTextCore

final class PromptBuilderTests: XCTestCase {
    func testBuildMergesSourcesInPriorityOrderAndIncludesTermsOnce() throws {
        let result = try PromptBuilder.build(
            commonTerms: ["SPECIFIQUE", "OGSTM"],
            glossaryTerms: ["復盛", "OGSTM", "江總"],
            temporaryTerms: ["江總", "One Company One Mission"]
        )

        XCTAssertEqual(
            result.terms,
            ["SPECIFIQUE", "OGSTM", "復盛", "江總", "One Company One Mission"]
        )
        XCTAssertTrue(result.prompt.hasPrefix("這是一段中文會議錄音。"))
        XCTAssertTrue(result.prompt.contains("不要摘要、改寫、刪除或補充"))
        XCTAssertTrue(result.prompt.contains("沒有出現的詞彙不要自行加入"))
        XCTAssertTrue(
            result.prompt.hasSuffix(
                "SPECIFIQUE\nOGSTM\n復盛\n江總\nOne Company One Mission"
            )
        )
    }

    func testBuildWithoutTermsReturnsOnlyFidelityInstruction() throws {
        let result = try PromptBuilder.build(
            commonTerms: [],
            glossaryTerms: [],
            temporaryTerms: []
        )

        XCTAssertEqual(result.terms, [])
        XCTAssertEqual(
            result.prompt,
            "這是一段中文會議錄音。請忠實轉錄音訊內容，不要摘要、改寫、刪除或補充。"
        )
        XCTAssertFalse(result.prompt.contains("以下詞彙"))
    }

    func testMaximumTermCountIsAccepted() throws {
        let terms = (0..<PromptBuilder.maximumTerms).map { "詞\($0)" }

        let result = try PromptBuilder.build(
            commonTerms: terms,
            glossaryTerms: [],
            temporaryTerms: []
        )

        XCTAssertEqual(result.terms.count, PromptBuilder.maximumTerms)
    }

    func testTooManyTermsReportsActualAndMaximumCounts() {
        let terms = (0...PromptBuilder.maximumTerms).map { "詞\($0)" }

        XCTAssertThrowsError(
            try PromptBuilder.build(
                commonTerms: terms,
                glossaryTerms: [],
                temporaryTerms: []
            )
        ) { error in
            guard
                let promptError = error as? PromptBuilderError,
                case let .tooManyTerms(actual, maximum) = promptError
            else {
                return XCTFail("預期 tooManyTerms，實際為 \(error)")
            }
            XCTAssertEqual(actual, PromptBuilder.maximumTerms + 1)
            XCTAssertEqual(maximum, PromptBuilder.maximumTerms)
        }
    }

    func testMaximumUnicodeScalarCountIsAccepted() throws {
        let term = String(repeating: "字", count: PromptBuilder.maximumUnicodeScalars)

        let result = try PromptBuilder.build(
            commonTerms: [term],
            glossaryTerms: [],
            temporaryTerms: []
        )

        XCTAssertEqual(result.terms, [term])
    }

    func testTooManyUnicodeScalarsReportsActualAndMaximumCounts() {
        let term = String(
            repeating: "字",
            count: PromptBuilder.maximumUnicodeScalars + 1
        )

        XCTAssertThrowsError(
            try PromptBuilder.build(
                commonTerms: [term],
                glossaryTerms: [],
                temporaryTerms: []
            )
        ) { error in
            guard
                let promptError = error as? PromptBuilderError,
                case let .tooManyCharacters(actual, maximum) = promptError
            else {
                return XCTFail("預期 tooManyCharacters，實際為 \(error)")
            }
            XCTAssertEqual(actual, PromptBuilder.maximumUnicodeScalars + 1)
            XCTAssertEqual(maximum, PromptBuilder.maximumUnicodeScalars)
        }
    }
}

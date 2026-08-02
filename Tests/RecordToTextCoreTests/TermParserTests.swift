import XCTest
@testable import RecordToTextCore

final class TermParserTests: XCTestCase {
    func testParseAcceptsEverySpecifiedSeparatorAndTrimsItems() {
        let input = " 復盛,OGSTM，五大構面、江總;Dashboard；思考圖\nSPECIFIQUE\rOne Company One Mission "

        XCTAssertEqual(
            TermParser.parse(input),
            [
                "復盛",
                "OGSTM",
                "五大構面",
                "江總",
                "Dashboard",
                "思考圖",
                "SPECIFIQUE",
                "One Company One Mission"
            ]
        )
    }

    func testParseRemovesEmptyItemsButPreservesInternalWhitespace() {
        let input = " ,；\n  One  Company  One  Mission  ,, 專案 A "

        XCTAssertEqual(
            TermParser.parse(input),
            ["One  Company  One  Mission", "專案 A"]
        )
    }

    func testParseAcceptsSpaceSeparatedCJKTermsWithoutBreakingMixedTerms() {
        XCTAssertEqual(
            TermParser.parse("味全 典華 學習長"),
            ["味全", "典華", "學習長"]
        )
        XCTAssertEqual(
            TermParser.parse("One Company One Mission, 專案 A"),
            ["One Company One Mission", "專案 A"]
        )
    }

    func testParseUsesExactCaseSensitiveDeduplicationAndFirstOccurrenceOrder() {
        let input = "OGSTM,ogstm,OGSTM, Ogstm ,ogstm"

        XCTAssertEqual(
            TermParser.parse(input),
            ["OGSTM", "ogstm", "Ogstm"]
        )
    }

    func testMergePreservesSourcePriorityAndDropsLaterDuplicates() {
        let common = ["SPECIFIQUE", "OGSTM"]
        let glossary = ["復盛", "OGSTM", "江總"]
        let temporary = ["江總", "本次限定", "SPECIFIQUE"]

        XCTAssertEqual(
            TermParser.merge([common, glossary, temporary]),
            ["SPECIFIQUE", "OGSTM", "復盛", "江總", "本次限定"]
        )
    }

    func testEmptyInputProducesNoTerms() {
        XCTAssertEqual(TermParser.parse(" \n，、；,"), [])
        XCTAssertEqual(TermParser.merge([]), [])
    }
}

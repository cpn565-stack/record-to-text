import XCTest
@testable import RecordToTextCore

final class OutputContractValidatorTests: XCTestCase {
    func testTimeHeadingsDoNotHidePromptEchoOrChangeValidTranscript() throws {
        let prompt = "請忠實轉錄音訊內容，不要摘要、改寫、刪除或補充。"
        let heading = "[00:20:00 - 00:30:00]\n\n"
        XCTAssertThrowsError(try OutputContractValidator.validate(
            text: heading + prompt + "\n實際內容。", path: "timed.txt", prompt: prompt
        )) { error in
            XCTAssertEqual(error as? OutputContractValidationError, .promptEcho("timed.txt"))
        }
        let valid = heading + "實際內容。"
        XCTAssertEqual(try OutputContractValidator.validate(
            text: valid, path: "timed.txt", prompt: prompt
        ), valid)
    }

    func testRejectsLeadingCompleteGlossaryEcho() throws {
        let prompt = """
        這是一段中文會議錄音。請忠實轉錄音訊內容，不要摘要、改寫、刪除或補充。
        以下詞彙可能出現在錄音中。只有當音訊內容相符時才使用以下寫法；沒有出現的詞彙不要自行加入：

        味全
        典華
        學習長
        """

        XCTAssertThrowsError(
            try OutputContractValidator.validate(
                text: "味全 典華 學習長。 嗯，真正的會議內容。",
                path: "/tmp/leading-glossary-echo.txt",
                prompt: prompt
            )
        ) { error in
            XCTAssertEqual(
                error as? OutputContractValidationError,
                .promptEcho("/tmp/leading-glossary-echo.txt")
            )
        }
    }

    func testRejectsLeadingEchoFromSpaceSeparatedCJKTermSnapshot() throws {
        let prompt = """
        這是一段中文會議錄音。請忠實轉錄音訊內容，不要摘要、改寫、刪除或補充。
        以下詞彙可能出現在錄音中。只有當音訊內容相符時才使用以下寫法；沒有出現的詞彙不要自行加入：

        味全 典華 學習長
        """

        XCTAssertThrowsError(
            try OutputContractValidator.validate(
                text: "味全 典華 學習長。",
                path: "/tmp/space-separated-glossary-echo.txt",
                prompt: prompt
            )
        ) { error in
            XCTAssertEqual(
                error as? OutputContractValidationError,
                .promptEcho("/tmp/space-separated-glossary-echo.txt")
            )
        }
    }

    func testRejectsLeadingGlossaryEchoWithSentencePunctuationBetweenTerms() throws {
        let prompt = """
        這是一段中文會議錄音。請忠實轉錄音訊內容，不要摘要、改寫、刪除或補充。
        以下詞彙可能出現在錄音中。只有當音訊內容相符時才使用以下寫法；沒有出現的詞彙不要自行加入：

        味全
        典華
        學習長
        """

        XCTAssertThrowsError(
            try OutputContractValidator.validate(
                text: "味全。典華。學習長。",
                path: "/tmp/punctuated-glossary-echo.txt",
                prompt: prompt
            )
        ) { error in
            XCTAssertEqual(
                error as? OutputContractValidationError,
                .promptEcho("/tmp/punctuated-glossary-echo.txt")
            )
        }
    }
}

import XCTest
@testable import RecordToTextCore

final class TranscriptTimestampValidatorTests: XCTestCase {
    func testValidIntervalsAndEarlierTopicChangesRemainByteForByte() {
        let text = "[19:58 - 21:00]\n\n講者 1：原話。\n\n[21:00 - 24:58]\n\n講者 2：嗯。\n"
        let result = TranscriptTimestampValidator.validate(text: text, startSeconds: 1198.7, endSeconds: 1498.7)
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.review.disposition, .unchanged)
    }

    func testOvershootingFinalEndIsClampedWithoutChangingUtterances() {
        let text = "[39:50 - 44:50]\n\n講者 1：這個...\n講者 2：對。\n"
        let result = TranscriptTimestampValidator.validate(text: text, startSeconds: 2390.6, endSeconds: 2423.36)
        XCTAssertEqual(result.text, text.replacingOccurrences(of: "44:50", with: "40:23"))
        XCTAssertEqual(result.review.disposition, .boundsCorrected)
        XCTAssertFalse(result.review.needsReview)
    }

    func testMissingFifteenMinutesOfHeadingsUsesActualRangeWithoutInventingAlignment() {
        let body = "講者 1：" + String(repeating: "內容仍然完整。\n", count: 200)
        let result = TranscriptTimestampValidator.validate(text: "[19:58 - 24:58]\n\n" + body,
            startSeconds: 1198, endSeconds: 2398)
        XCTAssertTrue(result.text.hasPrefix("[19:58 - 39:58]"))
        XCTAssertTrue(result.text.contains(body.trimmingCharacters(in: .newlines)))
        XCTAssertFalse(result.text.contains("[24:58 - 29:58]"))
        XCTAssertTrue(result.review.needsReview)
        XCTAssertEqual(result.review.issues, [.missingIntervals])
        XCTAssertEqual(result.text.components(separatedBy: TranscriptTimestampValidator.reviewNotice).count, 2)
        XCTAssertEqual(TranscriptTimestampValidator.validate(text: result.text, startSeconds: 1198, endSeconds: 2398).text, result.text)
    }

    func testBadOrderOverlapAndResetNeverShiftTextToGuessedTimes() {
        for text in [
            "[00:00 - 05:00]\n甲：前\n[04:59 - 10:00]\n乙：後",
            "[05:00 - 10:00]\n甲：前\n[00:00 - 05:00]\n乙：後",
            "[00:00 - 05:00]\n甲：前\n[06:00 - 10:00]\n乙：後"
        ] {
            let result = TranscriptTimestampValidator.validate(text: text, startSeconds: 0, endSeconds: 600)
            XCTAssertTrue(result.review.needsReview)
            XCTAssertTrue(result.text.contains("甲：前\n乙：後"))
            XCTAssertTrue(result.text.hasPrefix("[00:00 - 10:00]"))
        }
        let reset = TranscriptTimestampValidator.validate(text: "[00:00 - 05:00]\n甲：原話。", startSeconds: 1200, endSeconds: 1500)
        XCTAssertTrue(reset.review.issues.contains(.outsideSegment))
    }

    func testMissingAndMalformedMarkersPreserveContentAndNonTimeAnnotations() {
        for marker in ["", "[00:99 - 05:00]\n", "[00:00 - 未知]\n"] {
            let body = "講者 1：emoji 👨‍👩‍👧‍👦、[00:01 - 00:02] 是口述範例。\n[聽不清楚]\n講者 2：嗯。"
            let result = TranscriptTimestampValidator.validate(text: marker + body, startSeconds: 0, endSeconds: 300)
            XCTAssertTrue(result.review.needsReview)
            XCTAssertTrue(result.text.hasSuffix(body))
        }
    }

    func testSpeechBeforeFirstMarkerAndUnmarkedTailAreDetected() {
        let prefix = TranscriptTimestampValidator.validate(text: "講者 1：開頭。\n[00:00 - 05:00]\n講者 2：後面。", startSeconds: 0, endSeconds: 300)
        XCTAssertTrue(prefix.review.needsReview)
        XCTAssertTrue(prefix.text.contains("講者 1：開頭。"))
        let tail = TranscriptTimestampValidator.validate(text: "[00:00 - 05:00]\n講者 1：完整內容。", startSeconds: 0, endSeconds: 301)
        // One second rounding tolerance may correct a known outer endpoint.
        XCTAssertEqual(tail.review.disposition, .boundsCorrected)
    }

    func testLongAudioHourNotationAndRoundingAreSupported() {
        let result = TranscriptTimestampValidator.validate(text: "[01:00:00 – 01:05:00]\n講者 1：你好。", startSeconds: 3600, endSeconds: 3900)
        XCTAssertEqual(result.review.disposition, .unchanged)
        let rounding = TranscriptTimestampValidator.validate(text: "[19:59 - 24:59]\n講者 1：你好。", startSeconds: 1198.8, endSeconds: 1498.8)
        XCTAssertEqual(rounding.text, "[19:58 - 24:58]\n講者 1：你好。")
    }

    func testPromptIncludesActualEndAndAllExpectedIntervals() {
        let prompt = GeminiTranscriptPrompt.promptByAppendingTimeBounds("原 Prompt", startSeconds: 1198.2, endSeconds: 2423.36)
        XCTAssertTrue(prompt.hasPrefix("原 Prompt"))
        for interval in ["[19:58 - 24:58]", "[24:58 - 29:58]", "[29:58 - 34:58]", "[34:58 - 39:58]", "[39:58 - 40:23]"] {
            XCTAssertTrue(prompt.contains(interval))
        }
        XCTAssertFalse(prompt.contains("44:58"))
    }
}

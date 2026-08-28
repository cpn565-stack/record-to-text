import Foundation
import XCTest
@testable import RecordToTextCore

final class SpeakerRosterTests: XCTestCase {
    func testRosterLocksFullNamesAcrossNicknameAndHomophoneLabels() {
        var roster = SpeakerRoster()
        roster.observe(
            transcript: """
            彭建文：哈囉大家好，我是彭建文。
            郝哥：大家好，我是郝旭烈郝哥。
            """,
            segmentIndex: 1
        )

        XCTAssertEqual(
            roster.identities.map(\.canonicalLabel),
            ["彭建文", "郝旭烈"]
        )

        let later = """
        建文：我們接著談下一題。
        豪哥：好，我補充一點。
        """
        roster.observe(transcript: later, segmentIndex: 2)
        XCTAssertEqual(
            roster.normalizingSpeakerLabels(in: later),
            """
            彭建文：我們接著談下一題。
            郝旭烈：好，我補充一點。
            """
        )
        XCTAssertTrue(
            roster.identities[1].aliases.contains("豪哥")
        )
    }

    func testGenericLabelUsesSelfIntroductionAndNewSpeakerIsPreserved() {
        var roster = SpeakerRoster()
        roster.observe(
            transcript: """
            講者 1：大家好，我叫林廣哲。
            Ted：我稍後再補充。
            """,
            segmentIndex: 3
        )
        XCTAssertEqual(
            roster.identities.map(\.canonicalLabel),
            ["林廣哲", "Ted"]
        )
    }

    func testKnownTermCanCorrectSpeakerSelfIntroduction() {
        var roster = SpeakerRoster()
        roster.observe(
            transcript: "郝哥：大家好，我是郝旭昇郝哥。",
            segmentIndex: 1,
            knownTerms: ["郝旭烈", "盛和塾"]
        )
        XCTAssertEqual(roster.identities.first?.canonicalLabel, "郝旭烈")
    }

    func testPromptInstructionUsesCanonicalLabels() throws {
        var roster = SpeakerRoster()
        roster.observe(
            transcript: "彭建文：我是彭建文。\n郝哥：我是郝旭烈郝哥。",
            segmentIndex: 1
        )
        let instruction = try XCTUnwrap(roster.promptInstruction)
        XCTAssertTrue(instruction.contains("彭建文"))
        XCTAssertTrue(instruction.contains("郝旭烈"))
        XCTAssertTrue(instruction.contains("不要改名"))
    }
}

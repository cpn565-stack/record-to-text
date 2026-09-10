import Foundation
import XCTest
@testable import RecordToTextCore

final class SpeakerRosterTests: XCTestCase {
    func testNamesNicknamesAndHomophonesRemainAsTranscribed() {
        var roster = SpeakerRoster()
        roster.observe(transcript: "彭建文：我是彭建文。\n郝哥：我是郝旭烈郝哥。", segmentIndex: 1)
        let later = "建文：我們接著談下一題。\n豪哥：好，我補充一點。"
        roster.observe(transcript: later, segmentIndex: 2)
        XCTAssertEqual(roster.normalizingSpeakerLabels(in: later), later)
        XCTAssertEqual(roster.identities.map(\.canonicalLabel), ["彭建文", "郝哥", "建文", "豪哥"])
        XCTAssertTrue(roster.identities.allSatisfy { $0.aliases.isEmpty })
    }

    func testGenericLabelsAndOrdinaryUtterancesDoNotBecomeCrossSegmentNames() {
        var roster = SpeakerRoster()
        for sentence in ["我是負責這個專案的窗口。", "我是覺得還可以。", "我叫林廣哲。"] {
            let text = "講者 1：\(sentence)\n主持人：請繼續。"
            roster.observe(transcript: text, segmentIndex: 1)
            XCTAssertEqual(roster.normalizingSpeakerLabels(in: text), text)
        }
        XCTAssertTrue(roster.isEmpty)
        XCTAssertNil(roster.promptInstruction)
    }

    func testKnownTermsDoNotProveIdentityAndSuffixOrderDoesNotMatter() {
        for names in [["王小明", "陳小明"], ["陳小明", "王小明"]] {
            var roster = SpeakerRoster()
            roster.observe(transcript: names.map { "\($0)：早安。" }.joined(separator: "\n"), segmentIndex: 1)
            let text = "小明：我補充一下。\n郝哥：大家好，我是郝旭昇郝哥。"
            roster.observe(transcript: text, segmentIndex: 2, knownTerms: ["郝旭烈"])
            XCTAssertEqual(roster.normalizingSpeakerLabels(in: text), text)
        }
    }

    func testLegacyAliasesCannotRenameTextAndPromptExpressesUncertainty() {
        let roster = SpeakerRoster(identities: [
            SpeakerIdentity(canonicalLabel: "王小明", aliases: ["講者 1", "小明"],
                firstSeenSegment: 1, confidence: .explicit)])
        let text = "講者 1：我叫陳大文。\n小明：我是負責這個專案的窗口。"
        XCTAssertEqual(roster.normalizingSpeakerLabels(in: text), text)
        XCTAssertTrue(roster.promptInstruction?.contains("僅供參考") == true)
        XCTAssertFalse(roster.promptInstruction?.contains("必須使用") == true)
        XCTAssertFalse(roster.promptInstruction?.contains("曾出現") == true)
    }
}

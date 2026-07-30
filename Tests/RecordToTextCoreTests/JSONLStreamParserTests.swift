import Foundation
import XCTest
@testable import RecordToTextCore

final class JSONLStreamParserTests: XCTestCase {
    func testLivenessMonitorWarnsOnceUntilActivityResumes() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let monitor = HelperLivenessMonitor(startedAt: start)

        XCTAssertFalse(
            monitor.consumeWarningIfInactive(
                now: start.addingTimeInterval(29),
                timeout: 30
            )
        )
        XCTAssertTrue(
            monitor.consumeWarningIfInactive(
                now: start.addingTimeInterval(30),
                timeout: 30
            )
        )
        XCTAssertFalse(
            monitor.consumeWarningIfInactive(
                now: start.addingTimeInterval(60),
                timeout: 30
            )
        )

        monitor.recordActivity(at: start.addingTimeInterval(61))
        XCTAssertTrue(
            monitor.consumeWarningIfInactive(
                now: start.addingTimeInterval(91),
                timeout: 30
            )
        )
    }

    func testFixtureParsesExpectedEventsAndFields() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "events",
                withExtension: "jsonl",
                subdirectory: "Fixtures"
            )
        )
        let data = try Data(contentsOf: fixtureURL)
        var parser = JSONLStreamParser()

        var events = try parser.append(data)
        events.append(contentsOf: try parser.finish())

        XCTAssertEqual(
            events.map(\.type),
            ["capability", "stage", "progress", "heartbeat", "warning", "completed"]
        )
        XCTAssertEqual(events[0].supportsSystemPrompt, true)
        XCTAssertEqual(events[0].supportsContext, false)
        XCTAssertEqual(events[1].value, "loading_model")
        XCTAssertEqual(events[2].current, 12)
        XCTAssertEqual(events[2].total, 72)
        XCTAssertEqual(events[2].unit, "chunks")
        XCTAssertEqual(events[4].code, "glossary_hint")
        XCTAssertEqual(events[4].recoverable, true)
        XCTAssertEqual(events[5].outputPath, "/tmp/raw.txt")
        XCTAssertEqual(events[5].durationSeconds, 95.4)
    }

    func testAppendHandlesArbitraryByteBoundariesIncludingUnicode() throws {
        let text = """
        {"type":"log","level":"info","message":"處理第十二個區塊"}
        {"type":"completed","outputPath":"/tmp/逐字稿.txt","durationSeconds":1.5}
        """
        let data = try XCTUnwrap(text.data(using: .utf8))
        var parser = JSONLStreamParser()
        var events: [HelperEvent] = []
        var start = 0

        while start < data.count {
            let end = min(start + 3, data.count)
            events.append(
                contentsOf: try parser.append(data.subdata(in: start..<end))
            )
            start = end
        }
        events.append(contentsOf: try parser.finish())

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].message, "處理第十二個區塊")
        XCTAssertEqual(events[1].outputPath, "/tmp/逐字稿.txt")
    }

    func testAppendAcceptsCRLFAndSkipsBlankLines() throws {
        let text = "\r\n{\"type\":\"stage\",\"value\":\"validating\"}\r\n\n"
        var parser = JSONLStreamParser()

        let events = try parser.append(Data(text.utf8))

        XCTAssertEqual(events, [HelperEvent(type: "stage", value: "validating")])
        XCTAssertEqual(try parser.finish(), [])
    }

    func testFinishDecodesFinalLineWithoutNewline() throws {
        var parser = JSONLStreamParser()

        XCTAssertEqual(
            try parser.append(Data(#"{"type":"heartbeat"}"#.utf8)),
            []
        )
        XCTAssertEqual(
            try parser.finish(),
            [HelperEvent(type: "heartbeat")]
        )
        XCTAssertEqual(try parser.finish(), [])
    }

    func testInvalidJSONReportsOriginalLine() {
        var parser = JSONLStreamParser()
        let invalidLine = #"{"type":"progress","current":}"#

        XCTAssertThrowsError(
            try parser.append(Data("\(invalidLine)\n".utf8))
        ) { error in
            guard
                let parserError = error as? JSONLParserError,
                case let .invalidJSON(line, _) = parserError
            else {
                return XCTFail("預期 invalidJSON，實際為 \(error)")
            }
            XCTAssertEqual(line, invalidLine)
        }
    }

    func testInvalidUTF8IsRejected() {
        var parser = JSONLStreamParser()

        XCTAssertNoThrow(try parser.append(Data([0xFF])))
        XCTAssertThrowsError(try parser.finish()) { error in
            guard
                let parserError = error as? JSONLParserError,
                case .invalidUTF8 = parserError
            else {
                return XCTFail("預期 invalidUTF8，實際為 \(error)")
            }
        }
    }

    func testUnknownEventTypeRemainsForwardCompatible() throws {
        var parser = JSONLStreamParser()
        let events = try parser.append(
            Data("{\"type\":\"future_event\",\"message\":\"仍可解析\"}\n".utf8)
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "future_event")
        XCTAssertEqual(events[0].message, "仍可解析")
    }
}

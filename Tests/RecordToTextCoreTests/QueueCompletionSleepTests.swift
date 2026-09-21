import AppKit
import XCTest
@testable import RecordToTextCore
@testable import RecordToTextApp

@MainActor
final class QueueCompletionSleepTests: XCTestCase {
    private func job(_ backend: ASRBackendType = .googleAIStudio) -> TranscriptionJob {
        TranscriptionJob(sourcePath: "/fixture.wav", snapshot: .init(modelID: "fixture", glossaryID: nil,
            glossaryName: nil, terms: [], prompt: "fixture", outputLocationMode: .sameAsSource,
            outputDirectory: "/tmp", keepRawTranscript: false, backendType: backend))
    }
    private func complete(_ input: TranscriptionJob, completeness: OutputCompleteness = .complete) -> TranscriptionJob {
        var job = input
        job.startedAt = Date(); job.stage = .completed; job.outputCompleteness = completeness
        return job
    }

    func testDefaultOffAndEmptyOrHistoricalJobsDoNotStartCountdown() async throws {
        let gate = RecoveryTestGate()
        var sleeps = 0
        let coordinator = QueueCompletionSleepCoordinator(wait: { _ in try await gate.wait() }, requestSleep: { sleeps += 1 })
        let done = complete(job())
        coordinator.prepare = { true }
        coordinator.refresh(jobs: [done], blocked: false)
        XCTAssertFalse(coordinator.isEnabled)
        for history in [[], [done]] {
            coordinator.setEnabled(true, jobs: history)
            coordinator.refresh(jobs: history, blocked: false)
            XCTAssertNil(coordinator.countdownUntil)
        }
        XCTAssertEqual(sleeps, 0)
        coordinator.setEnabled(false, jobs: [])
    }

    func testMixedQueueCompletesOnceAndSurvivesZeroHistoryPruning() async throws {
        let gate = RecoveryTestGate()
        var sleeps = 0
        let coordinator = QueueCompletionSleepCoordinator(wait: { _ in try await gate.wait() }, requestSleep: { sleeps += 1 })
        coordinator.prepare = { true }
        let jobs = [job(.localQwen), job(.googleAIStudio), job(.vertexAI)]
        coordinator.setEnabled(true, jobs: jobs)
        coordinator.refresh(jobs: [complete(jobs[0]), jobs[1], jobs[2]], blocked: true)
        coordinator.refresh(jobs: [complete(jobs[1]), jobs[2]], blocked: true)
        coordinator.refresh(jobs: [complete(jobs[2])], blocked: true)
        coordinator.refresh(jobs: [], blocked: false)
        try await TestSupport.eventually { await gate.calls == 1 }
        XCTAssertNotNil(coordinator.countdownUntil)
        await gate.release()
        try await TestSupport.eventually { sleeps == 1 }
        XCTAssertFalse(coordinator.isEnabled)
        coordinator.refresh(jobs: [], blocked: false)
        await gate.release()
        XCTAssertEqual(sleeps, 1)
        XCTAssertEqual(coordinator.message, "已送出休眠要求。")
    }

    func testFailureGapUnknownCompletenessAndPausedWorkBlockSleep() async throws {
        for stage in [TranscriptionStage.failed, .interrupted, .completed] {
            var unfinished = job()
            let coordinator = QueueCompletionSleepCoordinator(requestSleep: { XCTFail("Incomplete job requested sleep") })
            coordinator.setEnabled(true, jobs: [unfinished])
            unfinished.stage = stage; unfinished.startedAt = Date()
            unfinished.outputCompleteness = stage == .completed ? .hasGaps : nil
            coordinator.refresh(jobs: [unfinished], blocked: false)
            XCTAssertNil(coordinator.countdownUntil)
            if stage == .completed {
                unfinished.outputCompleteness = .unknown
                coordinator.refresh(jobs: [unfinished], blocked: false)
                XCTAssertNil(coordinator.countdownUntil)
            }
            coordinator.setEnabled(false, jobs: [])
        }
    }

    func testContinuationReplacesFailedLogicalWorkAndOldHistoryDoesNotBlock() async throws {
        let gate = RecoveryTestGate()
        let coordinator = QueueCompletionSleepCoordinator(wait: { _ in try await gate.wait() }, requestSleep: {})
        var old = job(); old.stage = .failed
        var parent = job()
        coordinator.setEnabled(true, jobs: [old, parent])
        parent.stage = .failed; parent.startedAt = Date()
        coordinator.refresh(jobs: [old, parent], blocked: false)
        XCTAssertNil(coordinator.countdownUntil)
        var child = job(); child.continuationParentJobID = parent.id
        coordinator.refresh(jobs: [parent, child], blocked: true)
        coordinator.refresh(jobs: [parent, complete(child)], blocked: false)
        try await TestSupport.eventually { await gate.calls == 1 }
        coordinator.setEnabled(false, jobs: [])
    }

    func testNewWorkAndBusyChangesRestartFullCountdown() async throws {
        let gate = RecoveryTestGate()
        var sleeps = 0
        let coordinator = QueueCompletionSleepCoordinator(wait: { _ in try await gate.wait() }, requestSleep: { sleeps += 1 })
        coordinator.prepare = { true }
        let first = job(), second = job()
        coordinator.setEnabled(true, jobs: [first])
        coordinator.refresh(jobs: [complete(first)], blocked: false)
        try await TestSupport.eventually { await gate.calls == 1 }
        coordinator.refresh(jobs: [complete(first)], blocked: true)
        XCTAssertNil(coordinator.countdownUntil)
        coordinator.refresh(jobs: [complete(first), second], blocked: false)
        await gate.release()
        XCTAssertEqual(sleeps, 0)
        coordinator.refresh(jobs: [complete(first), complete(second)], blocked: false)
        try await TestSupport.eventually { await gate.calls == 2 }
        await gate.release()
        try await TestSupport.eventually { sleeps == 1 }
    }

    func testCancellationDeletionAndUserUncheckingConsumeArming() async throws {
        for action in 0..<3 {
            let gate = RecoveryTestGate()
            let coordinator = QueueCompletionSleepCoordinator(wait: { _ in try await gate.wait() }, requestSleep: { XCTFail("Cancelled arming requested sleep") })
            let pending = job()
            coordinator.setEnabled(true, jobs: [pending])
            if action == 0 { coordinator.cancelWork(pending.id) }
            if action == 1 { coordinator.refresh(jobs: [], blocked: false) }
            if action == 2 {
                coordinator.refresh(jobs: [complete(pending)], blocked: false)
                try await TestSupport.eventually { await gate.calls == 1 }
                coordinator.setEnabled(false, jobs: [])
            }
            coordinator.refresh(jobs: [complete(pending)], blocked: false)
            await gate.release()
            XCTAssertFalse(coordinator.isEnabled)
            XCTAssertNil(coordinator.countdownUntil)
        }
    }

    func testNewJobDuringFinalFlushInvalidatesStaleCallback() async throws {
        let countdown = RecoveryTestGate(), flush = RecoveryTestGate()
        var sleeps = 0
        let coordinator = QueueCompletionSleepCoordinator(wait: { _ in try await countdown.wait() }, requestSleep: { sleeps += 1 })
        coordinator.prepare = { try await flush.wait(); return true }
        let first = job(), next = job()
        coordinator.setEnabled(true, jobs: [first])
        coordinator.refresh(jobs: [complete(first)], blocked: false)
        try await TestSupport.eventually { await countdown.calls == 1 }
        await countdown.release()
        try await TestSupport.eventually { await flush.calls == 1 }
        coordinator.refresh(jobs: [complete(first), next], blocked: false)
        await flush.release()
        XCTAssertNil(coordinator.countdownUntil)
        XCTAssertEqual(sleeps, 0)
        coordinator.setEnabled(false, jobs: [])
    }

    func testSaveFailureAndSystemRefusalAreVisibleAndDoNotLoop() async throws {
        for failingSave in [true, false] {
            let gate = RecoveryTestGate()
            var sleepRequests = 0
            var events: [QueueSleepEvent] = []
            let coordinator = QueueCompletionSleepCoordinator(wait: { _ in try await gate.wait() }, requestSleep: {
                sleepRequests += 1
                throw SystemSleepService.Failure(code: -1)
            }, logEvent: { events.append($0) })
            coordinator.prepare = {
                if failingSave { throw CocoaError(.fileWriteOutOfSpace) }
                return true
            }
            let pending = job()
            coordinator.setEnabled(true, jobs: [pending])
            coordinator.refresh(jobs: [complete(pending)], blocked: false)
            try await TestSupport.eventually { await gate.calls == 1 }
            await gate.release()
            try await TestSupport.eventually { coordinator.message != nil }
            XCTAssertFalse(coordinator.isEnabled)
            XCTAssertEqual(sleepRequests, failingSave ? 0 : 1)
            XCTAssertEqual(events, failingSave ? [] : [.requestRejected(-1)])
            XCTAssertTrue(coordinator.message!.contains(failingSave ? "尚未保存" : "無法讓電腦休眠"))
            coordinator.refresh(jobs: [complete(pending)], blocked: false)
            XCTAssertNil(coordinator.countdownUntil)
        }
    }

    func testWakeClearsArming() async throws {
        let center = NotificationCenter()
        let coordinator = QueueCompletionSleepCoordinator(requestSleep: { XCTFail("Wake must not request sleep") }, notificationCenter: center)
        coordinator.setEnabled(true, jobs: [job()])
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await TestSupport.eventually { !coordinator.isEnabled }
    }

    func testAcceptedRequestAndSystemNotificationsHaveSeparateEvidence() async throws {
        let center = NotificationCenter(), gate = RecoveryTestGate()
        var events: [QueueSleepEvent] = [], requests = 0
        let coordinator = QueueCompletionSleepCoordinator(wait: { _ in try await gate.wait() }, requestSleep: {
            requests += 1
        }, notificationCenter: center, logEvent: { events.append($0) })
        coordinator.prepare = { true }
        let pending = job(), done = complete(pending)
        coordinator.setEnabled(true, jobs: [pending])
        coordinator.refresh(jobs: [done], blocked: false)
        try await TestSupport.eventually { await gate.calls == 1 }
        await gate.release()
        try await TestSupport.eventually { events == [.requestAccepted] }
        XCTAssertEqual(coordinator.message, "已送出休眠要求。")
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await TestSupport.eventually { events == [.requestAccepted, .systemWillSleep] }
        XCTAssertEqual(coordinator.message, "已收到系統即將休眠通知。")
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await TestSupport.eventually { events == [.requestAccepted, .systemWillSleep, .systemDidWake] }
        coordinator.refresh(jobs: [done], blocked: false)
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertNil(coordinator.countdownUntil)
        XCTAssertEqual(requests, 1)
    }

    func testExternalSleepCancelsCountdownWithoutSendingRequest() async throws {
        let center = NotificationCenter(), gate = RecoveryTestGate()
        var events: [QueueSleepEvent] = []
        let coordinator = QueueCompletionSleepCoordinator(wait: { _ in try await gate.wait() }, requestSleep: {
            XCTFail("An external sleep must cancel the pending request")
        }, notificationCenter: center, logEvent: { events.append($0) })
        coordinator.prepare = { true }
        let pending = job()
        coordinator.setEnabled(true, jobs: [pending])
        coordinator.refresh(jobs: [complete(pending)], blocked: false)
        try await TestSupport.eventually { await gate.calls == 1 }
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await TestSupport.eventually { events == [.systemWillSleep] }
        await gate.release()
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertNil(coordinator.countdownUntil)
    }
}

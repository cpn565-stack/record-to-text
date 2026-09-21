import Foundation

public extension TranscriptionJob {
    var cloudContinuationID: UUID? { continuationJobID ?? networkContinuationJobID }
    var isCloudRecoveryPaused: Bool {
        continuationPending == true || (stage == .interrupted && (
            (networkRecovery != nil && networkRecovery?.state != .resolved) ||
            (serviceRecovery != nil && serviceRecovery?.state != .resolved)))
    }
}

/// Read-only validation and construction shared by every manual cloud resend.
/// The App saves the parent/child relationship before allowing execution.
public enum CloudJobContinuation {
    public static func make(from original: TranscriptionJob, paths: ApplicationPaths) throws -> TranscriptionJob {
        guard FileManager.default.fileExists(atPath: original.sourcePath) else {
            throw CloudResumeCheckpointError.incompatibleRecovery("找不到原始錄音")
        }
        var recoveryPath: String?
        let hasCompletedEvidence = original.failure?.partialTranscriptPath != nil ||
            max(original.networkRecovery?.completedSegmentCount ?? 0, original.serviceRecovery?.completedSegmentCount ?? 0) > 0
        if let path = original.failure?.recoveryDirectory {
            let manifestURL = URL(fileURLWithPath: path).appendingPathComponent(RecoveryScanner.segmentManifestFileName)
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                let manifest = try JSONDecoder().decode(AudioSegmentManifest.self, from: Data(contentsOf: manifestURL))
                let completed = manifest.segments.filter { $0.status == .completed || $0.status == .completedWithGaps }
                if !completed.isEmpty {
                    let checkpoint = try CloudResumeCheckpointLoader.load(recoveryDirectory: URL(fileURLWithPath: path),
                        job: original, sourceDuration: manifest.sourceDurationSeconds,
                        sourceTimeOffset: original.sourceSlice?.startSeconds ?? 0,
                        maximumSegmentDuration: manifest.maximumSegmentDurationSeconds, paths: paths)
                    guard checkpoint.reusableSegments.count == completed.count else {
                        throw CloudResumeCheckpointError.invalidManifest("已完成片段的文字檔遺失或損壞；未自動從頭重做")
                    }
                    recoveryPath = path
                } else if hasCompletedEvidence {
                    throw CloudResumeCheckpointError.invalidManifest("紀錄顯示已有完成片段，但檢查點沒有可沿用的片段；未自動從頭重做")
                }
            } else if hasCompletedEvidence {
                throw CloudResumeCheckpointError.missingManifest
            }
        } else if hasCompletedEvidence {
            throw CloudResumeCheckpointError.missingManifest
        }
        var next = TranscriptionJob(sourcePath: original.sourcePath,
            snapshot: original.snapshot.withGoogleAIStudioAPIKey(nil), sourceSlice: original.sourceSlice,
            resumeFromRecoveryDirectory: recoveryPath)
        next.continuationParentJobID = original.id
        next.cloudDiagnostics = original.cloudDiagnostics
        if let notBefore = original.serviceRecovery?.serverNotBefore, notBefore > Date() {
            var waiting = original.serviceRecovery!
            waiting.state = .coolingDown; waiting.stopReason = nil
            waiting.nextRetryAt = notBefore
            next.serviceRecovery = waiting
        }
        next.logLines.append(recoveryPath == nil ? "使用原工作設定重新送出。" : "重送未完成片段；已完成片段會驗證並沿用。")
        if original.networkRecovery?.resultUnknown == true || original.serviceRecovery?.resultUnknown == true {
            next.logLines.append("先前請求結果未知，重送未完成片段可能再次計費。")
        }
        return next
    }
}

#!/usr/bin/env python3
from pathlib import Path

path = Path("Tests/RecordToTextCoreTests/CloudResumeCheckpointTests.swift")
text = path.read_text(encoding="utf-8")
old = '''        let metadata = RecoveryScanner.RecoveryMetadata(
            schemaVersion: 2,
            recoveryKind: "cloudCheckpoint",
            jobID: oldJobID,
            sourcePath: sourcePath,
            sourceSlice: nil,
            backendType: .googleAIStudio,
            failureStage: TranscriptionStage.transcribing.rawValue,
            createdAt: Date(),
            technicalError: "HTTP 503",
            checkpointFile: RecoveryScanner.segmentManifestFileName,
            segmentsDirectory: RecoveryScanner.segmentsDirectoryName,
            partialTranscriptFile: RecoveryScanner.partialTranscriptFileName
        )
'''
new = '''        let metadata = RecoveryScanner.RecoveryMetadata(
            schemaVersion: 2,
            jobID: oldJobID,
            sourcePath: sourcePath,
            sourceSlice: nil,
            failureStage: TranscriptionStage.transcribing.rawValue,
            createdAt: Date(),
            technicalError: "HTTP 503",
            recoveryKind: "cloudCheckpoint",
            backendType: .googleAIStudio,
            checkpointFile: RecoveryScanner.segmentManifestFileName,
            segmentsDirectory: RecoveryScanner.segmentsDirectoryName,
            partialTranscriptFile: RecoveryScanner.partialTranscriptFileName
        )
'''
count = text.count(old)
if count != 1:
    raise SystemExit(f"expected one recovery metadata fixture, found {count}")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
print("Corrected RecoveryMetadata fixture argument order")

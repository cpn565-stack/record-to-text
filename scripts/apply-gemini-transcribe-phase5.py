#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
path = ROOT / "Sources/RecordToTextCore/TranscriptionEngine.swift"
text = path.read_text()

if "recoveredMetadataPath" in text:
    print("phase 5 already applied")
    raise SystemExit(0)

old = '''            let sourceTranscript = URL(fileURLWithPath: sourceRecord.outputPath)
            if fileManager.fileExists(atPath: sourceTranscript.path) {
                try fileManager.copyItem(
                    at: sourceTranscript,
                    to: recoveredTranscript
                )
            }
            recoveredRecords.append(
                AudioSegmentRecord(
                    segmentIndex: sourceRecord.segmentIndex,
                    segmentCount: sourceRecord.segmentCount,
                    startSeconds: sourceRecord.startSeconds,
                    endSeconds: sourceRecord.endSeconds,
                    audioPath: "",
                    outputPath: recoveredTranscript.path,
                    status: sourceRecord.status,
                    completedEventCount: sourceRecord.completedEventCount,
                    failureMessage: sourceRecord.failureMessage
                )
            )
'''
new = '''            let sourceTranscript = URL(fileURLWithPath: sourceRecord.outputPath)
            if fileManager.fileExists(atPath: sourceTranscript.path) {
                try fileManager.copyItem(
                    at: sourceTranscript,
                    to: recoveredTranscript
                )
            }

            let recoveredMetadataPath: String?
            if let sourceMetadataPath = sourceRecord.metadataPath {
                let sourceMetadata = URL(fileURLWithPath: sourceMetadataPath)
                let recoveredMetadata = recoveredSegments.appendingPathComponent(
                    String(
                        format: "segment-%04d.metadata.json",
                        sourceRecord.segmentIndex
                    )
                )
                if fileManager.fileExists(atPath: sourceMetadata.path) {
                    try fileManager.copyItem(
                        at: sourceMetadata,
                        to: recoveredMetadata
                    )
                    recoveredMetadataPath = recoveredMetadata.path
                } else {
                    recoveredMetadataPath = nil
                }
            } else {
                recoveredMetadataPath = nil
            }

            recoveredRecords.append(
                AudioSegmentRecord(
                    segmentIndex: sourceRecord.segmentIndex,
                    segmentCount: sourceRecord.segmentCount,
                    startSeconds: sourceRecord.startSeconds,
                    endSeconds: sourceRecord.endSeconds,
                    audioPath: "",
                    outputPath: recoveredTranscript.path,
                    metadataPath: recoveredMetadataPath,
                    status: sourceRecord.status,
                    completedEventCount: sourceRecord.completedEventCount,
                    failureMessage: sourceRecord.failureMessage
                )
            )
'''
if text.count(old) != 1:
    raise RuntimeError("could not patch cloud recovery metadata copy")
text = text.replace(old, new, 1)

old_comment = '''        // Recovery keeps only completed text. MP3 segments are intentionally
        // excluded because the original sourcePath can recreate them and audio
        // retention would unnecessarily duplicate sensitive data.
'''
new_comment = '''        // Recovery keeps completed text and optional structured metadata.
        // MP3 segments are intentionally excluded because the original
        // sourcePath can recreate them and audio retention would unnecessarily
        // duplicate sensitive data.
'''
if text.count(old_comment) != 1:
    raise RuntimeError("could not update cloud recovery comment")
text = text.replace(old_comment, new_comment, 1)

path.write_text(text)
print("phase 5 applied")

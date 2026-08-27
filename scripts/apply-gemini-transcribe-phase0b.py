#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
phase1 = ROOT / "scripts/apply-gemini-transcribe-phase1.py"
text = phase1.read_text()
old = '''    replace_once(
        models,
        \'\'\'        case vertexAIGCSBucket
        case vertexAIIncludeSummary
        // Legacy runtime-selection keys are intentionally ignored.
\'\'\',
        \'\'\'        case vertexAIGCSBucket
        case vertexAIIncludeSummary
        case cloudTransport
        case transcriptionOptions
        case resolvedLanguageCodes
        case resolvedCustomVocabulary
        case modelMaximumDurationSeconds
        case modelRecommendedSegmentDurationSeconds
        case vertexAISummaryModelID
        case allowDedicatedTranscribeFallbackToGeneralGemini
        // Legacy runtime-selection keys are intentionally ignored.
\'\'\'
    )
'''
new = '''    replace_once(
        models,
        \'\'\'        // Legacy runtime-selection keys are intentionally ignored.
\'\'\',
        \'\'\'        case cloudTransport
        case transcriptionOptions
        case resolvedLanguageCodes
        case resolvedCustomVocabulary
        case modelMaximumDurationSeconds
        case modelRecommendedSegmentDurationSeconds
        case vertexAISummaryModelID
        case allowDedicatedTranscribeFallbackToGeneralGemini
        // Legacy runtime-selection keys are intentionally ignored.
\'\'\'
    )
'''
if old in text:
    phase1.write_text(text.replace(old, new, 1))
    print("narrowed JobSnapshot coding-key anchor")
elif "case cloudTransport" in text and "Legacy runtime-selection" in text:
    print("JobSnapshot coding-key anchor already corrected")
else:
    raise RuntimeError("could not find JobSnapshot coding-key patch block")

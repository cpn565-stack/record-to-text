#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
path = root / "Tools/SelfTest/main.swift"
text = path.read_text(encoding="utf-8")
old = '''tests.check(
    {
        let presets = GeminiModelDescriptor.presetModels
        return presets.contains(where: { $0.id == "gemini-3.7-flash" })
            && presets.contains(where: { $0.id == "gemini-3.6-flash" })
            && presets.contains(where: { $0.id == "gemini-3.1-pro-preview" })
    }(),
    "GeminiModelDescriptor contains 3.7 Flash, 3.6 Flash and 3.1 Pro presets"
)
'''
new = '''tests.check(
    {
        let aiStudio = GoogleAIStudioModelCatalog.models
        let gcloud = GCloudModelCatalog.models
        let generalModelIDs = [
            "gemini-3.7-flash",
            "gemini-3.6-flash",
            "gemini-3.1-pro-preview"
        ]
        return generalModelIDs.allSatisfy { modelID in
            aiStudio.contains(where: { $0.id == modelID })
                && gcloud.contains(where: { $0.id == modelID })
        }
            && aiStudio.contains(where: {
                $0.id == "gemini-3.5-transcribe"
                    && $0.transport == .geminiInteractionsTranscribe
            })
            && gcloud.contains(where: {
                $0.id == "gemini-3.5-transcribe-preview"
                    && $0.transport == .agentPlatformTranscribe
                    && $0.requiredLocation == "global"
            })
    }(),
    "Provider cloud catalogs contain general Gemini and dedicated Transcribe models"
)
'''
if new in text:
    raise SystemExit(0)
if text.count(old) != 1:
    raise RuntimeError("legacy GeminiModelDescriptor self-test block not found exactly once")
path.write_text(text.replace(old, new, 1), encoding="utf-8")

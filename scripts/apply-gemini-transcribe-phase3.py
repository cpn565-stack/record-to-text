#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
models = ROOT / "Sources/RecordToTextCore/Models.swift"
view_model = ROOT / "Sources/RecordToTextApp/AppViewModel.swift"

if "metadataOutputPath = result.metadataOutputURL?.path" in view_model.read_text():
    print("phase 3 already applied")
    raise SystemExit(0)


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected one match, found {count}: {old[:100]!r}")
    path.write_text(text.replace(old, new, 1))


replace_once(
    models,
    '''    public var outputPath: String?
    public var rawOutputPath: String?
    public var createdAt: Date
''',
    '''    public var outputPath: String?
    public var rawOutputPath: String?
    public var metadataOutputPath: String?
    public var createdAt: Date
'''
)
replace_once(
    models,
    '''        self.outputPath = nil
        self.rawOutputPath = nil
        self.createdAt = createdAt
''',
    '''        self.outputPath = nil
        self.rawOutputPath = nil
        self.metadataOutputPath = nil
        self.createdAt = createdAt
'''
)
replace_once(
    models,
    '''    public let outputPath: String?
    public let stage: TranscriptionStage
''',
    '''    public let outputPath: String?
    public let metadataOutputPath: String?
    public let stage: TranscriptionStage
'''
)
replace_once(
    models,
    '''        sourceSlice: TranscriptionSourceSlice? = nil,
        outputPath: String?,
        stage: TranscriptionStage,
''',
    '''        sourceSlice: TranscriptionSourceSlice? = nil,
        outputPath: String?,
        metadataOutputPath: String? = nil,
        stage: TranscriptionStage,
'''
)
replace_once(
    models,
    '''        self.sourceSlice = sourceSlice
        self.outputPath = outputPath
        self.stage = stage
''',
    '''        self.sourceSlice = sourceSlice
        self.outputPath = outputPath
        self.metadataOutputPath = metadataOutputPath
        self.stage = stage
'''
)
replace_once(
    models,
    '''            sourceSlice: job.sourceSlice,
            outputPath: job.outputPath,
            stage: job.stage,
''',
    '''            sourceSlice: job.sourceSlice,
            outputPath: job.outputPath,
            metadataOutputPath: job.metadataOutputPath,
            stage: job.stage,
'''
)

replace_once(
    view_model,
    '''    var selectedModelName: String {
        switch settings.backendType {
        case .googleAIStudio:
            if let preset = GeminiModelDescriptor.presetModels.first(where: { $0.id == settings.googleAIStudioModelID }) {
                return "Google AI Studio (\\(preset.displayName))"
            }
            return "Google AI Studio (\\(settings.googleAIStudioModelID))"
        case .vertexAI:
            if let preset = GeminiModelDescriptor.presetModels.first(where: { $0.id == settings.vertexAIModelID }) {
                return "Vertex AI (\\(preset.displayName))"
            }
            return "Vertex AI (\\(settings.vertexAIModelID))"
        case .localQwen:
            return ASRModelDescriptor.descriptor(id: settings.selectedModelID)?.displayName
                ?? settings.selectedModelID
        }
    }
''',
    '''    var selectedModelName: String {
        switch settings.backendType {
        case .googleAIStudio:
            let descriptor = CloudModelCatalog.resolvedDescriptor(
                provider: .googleAIStudio,
                modelID: settings.googleAIStudioModelID
            )
            return "Google AI Studio (\\(descriptor.displayName))"
        case .vertexAI:
            let descriptor = CloudModelCatalog.resolvedDescriptor(
                provider: .vertexAI,
                modelID: settings.vertexAIModelID
            )
            return "Google Cloud (\\(descriptor.displayName))"
        case .localQwen:
            return ASRModelDescriptor.descriptor(id: settings.selectedModelID)?.displayName
                ?? settings.selectedModelID
        }
    }
'''
)

replace_once(
    view_model,
    '''    var appSubtitle: String {
        switch settings.backendType {
        case .googleAIStudio:
            return "透過 Google AI Studio (Gemini) 產出台灣繁體逐字稿。"
        case .vertexAI:
            return "透過 Google Cloud Vertex AI (Gemini)，直接產出台灣繁體逐字稿。"
        case .localQwen:
            return "把會議錄音留在這台 Mac，產生可繼續整理的台灣繁體文字稿。"
        }
    }
''',
    '''    var appSubtitle: String {
        switch settings.backendType {
        case .googleAIStudio:
            if selectedCloudModelIsDedicatedTranscribe {
                return "透過 Google AI Studio 專用 Gemini Transcribe 產出台灣繁體逐字稿。"
            }
            return "透過 Google AI Studio (Gemini) 產出台灣繁體逐字稿。"
        case .vertexAI:
            if selectedCloudModelIsDedicatedTranscribe {
                return "透過 gcloud / Agent Platform 專用 Gemini Transcribe 產出台灣繁體逐字稿。"
            }
            return "透過 Google Cloud Vertex AI (Gemini)，直接產出台灣繁體逐字稿。"
        case .localQwen:
            return "把會議錄音留在這台 Mac，產生可繼續整理的台灣繁體文字稿。"
        }
    }
'''
)

replace_once(
    view_model,
    '''    var selectedModelDetail: String? {
        switch settings.backendType {
        case .googleAIStudio:
            return GeminiModelDescriptor.presetModels.first(where: { $0.id == settings.googleAIStudioModelID })?.note
        case .vertexAI:
            return GeminiModelDescriptor.presetModels.first(where: { $0.id == settings.vertexAIModelID })?.note
        case .localQwen:
            return ASRModelDescriptor.descriptor(id: settings.selectedModelID)?.detail
        }
    }
''',
    '''    var selectedModelDetail: String? {
        switch settings.backendType {
        case .googleAIStudio, .vertexAI:
            return selectedCloudModelDescriptor?.note
        case .localQwen:
            return ASRModelDescriptor.descriptor(id: settings.selectedModelID)?.detail
        }
    }
'''
)

replace_once(
    view_model,
    '''        let outputDirectory: String
''',
    '''        let cloudConfiguration: ResolvedCloudJobConfiguration?
        do {
            cloudConfiguration = try resolveCloudJobConfiguration(
                terms: promptResult.terms
            )
        } catch {
            alert = UserFacingAlert(
                title: "專用轉錄設定無效",
                message: error.localizedDescription
            )
            return
        }

        let outputDirectory: String
'''
)

replace_once(
    view_model,
    '''                vertexAIModelID: settings.vertexAIModelID,
                vertexAIGCSBucket: settings.vertexAIGCSBucket,
                vertexAIIncludeSummary: settings.vertexAIIncludeSummary
            )
''',
    '''                vertexAIModelID: settings.vertexAIModelID,
                vertexAIGCSBucket: settings.vertexAIGCSBucket,
                vertexAIIncludeSummary: settings.vertexAIIncludeSummary,
                cloudTransport: cloudConfiguration?.descriptor.transport
                    ?? .geminiGenerateContent,
                transcriptionOptions: cloudConfiguration?.options ?? .default,
                resolvedLanguageCodes:
                    cloudConfiguration?.resolvedLanguageCodes ?? [],
                resolvedCustomVocabulary:
                    cloudConfiguration?.resolvedCustomVocabulary ?? [],
                modelMaximumDurationSeconds:
                    cloudConfiguration?.maximumAudioDurationSeconds,
                modelRecommendedSegmentDurationSeconds:
                    cloudConfiguration?.recommendedSegmentDurationSeconds,
                vertexAISummaryModelID: settings.vertexAISummaryModelID,
                allowDedicatedTranscribeFallbackToGeneralGemini:
                    settings.allowDedicatedTranscribeFallbackToGeneralGemini
            )
'''
)

replace_once(
    view_model,
    '''            if let sourceSlice {
                job.logLines.append(
                    "來源切片：\\(sourceSlice.displayName)，將依佇列順序逐段處理。"
                )
            }
            jobs.append(job)
''',
    '''            if let sourceSlice {
                job.logLines.append(
                    "來源切片：\\(sourceSlice.displayName)，將依佇列順序逐段處理。"
                )
            }
            if let cloudConfiguration,
               cloudConfiguration.descriptor.isDedicatedTranscription {
                job.logLines.append(
                    "專用轉錄：\\(cloudConfiguration.descriptor.displayName)，transport \\(cloudConfiguration.descriptor.transport.displayName)，單段 \\(Int(cloudConfiguration.recommendedSegmentDurationSeconds / 60)) 分鐘。"
                )
                if cloudConfiguration.usesLargeVocabulary {
                    job.logLines.append(
                        "提醒：Custom Vocabulary 共 \\(cloudConfiguration.resolvedCustomVocabulary.count) 個詞，超過建議的 \\(CloudTranscriptionPolicy.recommendedCustomVocabularyCount) 個；可執行，但品質可能受影響。"
                    )
                }
            }
            jobs.append(job)
'''
)

replace_once(
    view_model,
    '''                jobs[index].outputPath = result.outputURL.path
                jobs[index].rawOutputPath = result.rawOutputURL?.path
                jobs[index].completedAt = Date()
''',
    '''                jobs[index].outputPath = result.outputURL.path
                jobs[index].rawOutputPath = result.rawOutputURL?.path
                jobs[index].metadataOutputPath = result.metadataOutputURL?.path
                jobs[index].completedAt = Date()
'''
)

replace_once(
    view_model,
    '''                if cancellationArrivedTooLate {
                    jobs[index].logLines.append("取消要求送達時輸出已完成，因此保留完成結果。")
                }

                let completedJob = jobs[index]
''',
    '''                if let metadataURL = result.metadataOutputURL {
                    jobs[index].logLines.append(
                        "詳細轉錄 JSON：\\(metadataURL.lastPathComponent)"
                    )
                }
                if cancellationArrivedTooLate {
                    jobs[index].logLines.append("取消要求送達時輸出已完成，因此保留完成結果。")
                }

                let completedJob = jobs[index]
'''
)

print("phase 3 applied")

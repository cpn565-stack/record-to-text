import RecordToTextCore
import SwiftUI

struct CloudModelSettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    let provider: ASRBackendType

    private var models: [CloudModelDescriptor] {
        CloudModelCatalog.models(for: provider)
    }

    private var selectedModelID: String {
        switch provider {
        case .googleAIStudio:
            return viewModel.settings.googleAIStudioModelID
        case .vertexAI:
            return viewModel.settings.vertexAIModelID
        case .localQwen:
            return ""
        }
    }

    private var selectedDescriptor: CloudModelDescriptor {
        CloudModelCatalog.resolvedDescriptor(
            provider: provider,
            modelID: selectedModelID
        )
    }

    private var selection: Binding<String> {
        Binding(
            get: {
                models.contains(where: { $0.id == selectedModelID })
                    ? selectedModelID
                    : "custom"
            },
            set: { newValue in
                guard newValue != "custom" else { return }
                setModelID(newValue)
            }
        )
    }

    var body: some View {
        Picker("模型選擇", selection: selection) {
            ForEach(models) { model in
                Text(model.isPreview ? "\(model.displayName)・Preview" : model.displayName)
                    .tag(model.id)
            }
            Text("自訂一般模型 ID…").tag("custom")
        }

        if !models.contains(where: { $0.id == selectedModelID }) {
            TextField(
                "自訂一般模型 ID (Model ID)",
                text: Binding(
                    get: { selectedModelID },
                    set: { setModelID($0.isEmpty ? "gemini-3.7-flash" : $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            Text("自訂模型會使用既有 generateContent 契約；不會自動視為專用 Transcribe 模型。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Text(selectedDescriptor.note)
            .font(.caption)
            .foregroundStyle(.secondary)

        if selectedDescriptor.isDedicatedTranscription {
            DedicatedTranscriptionOptionsView(
                viewModel: viewModel,
                provider: provider,
                descriptor: selectedDescriptor
            )
        } else {
            Text("一般 Gemini 路徑會保留現有逐字稿 Prompt、內容安全處理與同系列模型 fallback。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func setModelID(_ modelID: String) {
        switch provider {
        case .googleAIStudio:
            viewModel.setSetting(\.googleAIStudioModelID, to: modelID)
        case .vertexAI:
            viewModel.setSetting(\.vertexAIModelID, to: modelID)
        case .localQwen:
            break
        }
    }
}

private struct DedicatedTranscriptionOptionsView: View {
    @ObservedObject var viewModel: AppViewModel
    let provider: ASRBackendType
    let descriptor: CloudModelDescriptor

    private var options: DedicatedTranscriptionOptions {
        switch provider {
        case .googleAIStudio:
            return viewModel.settings.googleAIStudioTranscriptionOptions
        case .vertexAI:
            return viewModel.settings.vertexAITranscriptionOptions
        case .localQwen:
            return .default
        }
    }

    var body: some View {
        Group {
            Divider()

            if descriptor.supportsSmartMode {
                Picker(
                    "轉錄模式",
                    selection: Binding(
                        get: { options.mode },
                        set: { newMode in
                            updateOptions { $0.mode = newMode }
                        }
                    )
                ) {
                    ForEach(DedicatedTranscriptionMode.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
            } else {
                LabeledContent("轉錄模式") {
                    Text("忠實逐字")
                        .foregroundStyle(.secondary)
                }
            }

            Picker(
                "語言提示",
                selection: Binding(
                    get: { options.languagePreference },
                    set: { newPreference in
                        updateOptions {
                            $0.languagePreference = newPreference
                        }
                    }
                )
            ) {
                ForEach(TranscriptionLanguagePreference.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }

            if options.languagePreference == .custom {
                TextField(
                    "BCP-47 語言代碼",
                    text: Binding(
                        get: { options.customLanguageCodes.joined(separator: ", ") },
                        set: { value in
                            updateOptions {
                                $0.customLanguageCodes = parseLanguageCodes(value)
                            }
                        }
                    ),
                    prompt: Text("例：cmn-Hant-TW, en-US")
                )
                .textFieldStyle(.roundedBorder)
            }

            Toggle(
                "辨識說話者",
                isOn: Binding(
                    get: { options.diarizationEnabled },
                    set: { enabled in
                        updateOptions { $0.diarizationEnabled = enabled }
                    }
                )
            )
            .disabled(
                !descriptor.supportsDiarization || options.mode == .smart
            )

            Toggle(
                "輸出逐字時間戳",
                isOn: Binding(
                    get: { options.wordTimestampsEnabled },
                    set: { enabled in
                        updateOptions { $0.wordTimestampsEnabled = enabled }
                    }
                )
            )
            .disabled(
                !descriptor.supportsWordTimestamps || options.mode == .smart
            )

            Toggle(
                "輸出詳細 JSON（說話者／時間資料）",
                isOn: Binding(
                    get: { options.writeMetadataJSON },
                    set: { enabled in
                        updateOptions { $0.writeMetadataJSON = enabled }
                    }
                )
            )

            if options.mode == .smart {
                Text("智慧整理會移除部分贅詞、重複與 false start，並做輕度格式整理；不適合需要嚴格逐字引述的錄音。此模式不能同時使用說話者辨識或逐字時間戳。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let requiredLocation = descriptor.requiredLocation {
                LabeledContent("Effective Location") {
                    Text(requiredLocation)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("單段安全切片") {
                Text("\(Int(descriptor.recommendedSegmentDurationSeconds / 60)) 分鐘")
                    .foregroundStyle(.secondary)
            }

            Text("詞庫會以 Custom Vocabulary 傳送；一般自由文字 Prompt 不會送給專用 Transcribe 模型。說話者標籤在長音檔中以每段為作用範圍，不保證跨段是同一人。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func updateOptions(
        _ mutation: (inout DedicatedTranscriptionOptions) -> Void
    ) {
        var updated = options
        mutation(&updated)
        updated = updated.normalizedForUI()
        switch provider {
        case .googleAIStudio:
            viewModel.setSetting(
                \.googleAIStudioTranscriptionOptions,
                to: updated
            )
        case .vertexAI:
            viewModel.setSetting(
                \.vertexAITranscriptionOptions,
                to: updated
            )
        case .localQwen:
            break
        }
    }

    private func parseLanguageCodes(_ value: String) -> [String] {
        value
            .split(whereSeparator: {
                $0 == "," || $0 == ";" || $0 == "\n" || $0 == " " || $0 == "\t"
            })
            .map(String.init)
    }
}

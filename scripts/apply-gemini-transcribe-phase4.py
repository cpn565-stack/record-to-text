#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
path = ROOT / "Sources/RecordToTextApp/SettingsView.swift"
text = path.read_text()

if "CloudModelSettingsView(\n                        viewModel: viewModel" in text:
    print("phase 4 already applied")
    raise SystemExit(0)

ai_scope = text.index('                if viewModel.settings.backendType == .googleAIStudio {')
ai_start = text.index('                    Picker(\n                        "模型選擇"', ai_scope)
ai_end = text.index('                    Text("Google AI Studio API 採用', ai_start)
ai_replacement = '''                    CloudModelSettingsView(
                        viewModel: viewModel,
                        provider: .googleAIStudio
                    )

'''
text = text[:ai_start] + ai_replacement + text[ai_end:]

vertex_scope = text.index('                if viewModel.settings.backendType == .vertexAI {')
vertex_start = text.index('                    Picker(\n                        "模型選擇"', vertex_scope)
vertex_end = text.index('                    Toggle(\n                        "附加內容摘要', vertex_start)
vertex_replacement = '''                    CloudModelSettingsView(
                        viewModel: viewModel,
                        provider: .vertexAI
                    )

'''
text = text[:vertex_start] + vertex_replacement + text[vertex_end:]

old_summary = '''                    Toggle(
                        "附加內容摘要（輸出不再是純逐字稿）",
                        isOn: setting(\\.vertexAIIncludeSummary)
                    )
                    Text("預設關閉。開啟後，Vertex AI 會在逐字稿後附加摘要；若要保留純原始逐字稿，請維持關閉。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
'''
new_summary = '''                    Toggle(
                        "附加內容摘要（輸出不再是純逐字稿）",
                        isOn: setting(\\.vertexAIIncludeSummary)
                    )
                    if viewModel.settings.vertexAIIncludeSummary {
                        Picker(
                            "摘要模型",
                            selection: setting(\\.vertexAISummaryModelID)
                        ) {
                            ForEach(GCloudModelCatalog.summaryModels) { model in
                                Text(model.displayName).tag(model.id)
                            }
                            if !GCloudModelCatalog.summaryModels.contains(where: {
                                $0.id == viewModel.settings.vertexAISummaryModelID
                            }) {
                                Text(
                                    "不支援：\\(viewModel.settings.vertexAISummaryModelID)"
                                )
                                .tag(viewModel.settings.vertexAISummaryModelID)
                            }
                        }
                    }
                    Text("預設關閉。摘要一律在所有片段合併後只產生一次；選擇專用 Transcribe 時，摘要會改由上方指定的一般 Gemini 模型執行。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
'''
if text.count(old_summary) != 1:
    raise RuntimeError("could not replace Vertex summary settings")
text = text.replace(old_summary, new_summary, 1)

old_location = '''                    TextField(
                        "GCP 區域 (Location)",
                        text: Binding(
                            get: { viewModel.settings.vertexAILocation },
                            set: { viewModel.setSetting(\\.vertexAILocation, to: $0.isEmpty ? "global" : $0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
'''
new_location = '''                    TextField(
                        "GCP 區域 (Location)",
                        text: Binding(
                            get: { viewModel.settings.vertexAILocation },
                            set: { viewModel.setSetting(\\.vertexAILocation, to: $0.isEmpty ? "global" : $0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .disabled(
                        viewModel.selectedCloudModelDescriptor?.requiredLocation != nil
                    )
'''
if text.count(old_location) != 1:
    raise RuntimeError("could not patch Vertex location control")
text = text.replace(old_location, new_location, 1)

old_footer = '''                    Text("Vertex AI 使用本機 `gcloud` 認證與 GCP 專案。所有設定皆會即時自動儲存。")
'''
new_footer = '''                    Text("Google Cloud 模式使用本機 `gcloud` 認證與 GCP 專案。一般 Gemini 走 Vertex generateContent；Gemini 3.5 Transcribe Preview 走 Agent Platform 專用契約。所有設定皆會即時自動儲存。")
'''
if text.count(old_footer) != 1:
    raise RuntimeError("could not patch Google Cloud footer")
text = text.replace(old_footer, new_footer, 1)

path.write_text(text)
print("phase 4 applied")

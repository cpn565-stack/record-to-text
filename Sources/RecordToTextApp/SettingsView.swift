import RecordToTextCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var resetChoice: ResetChoice?
    @State private var isTestingAPIKey = false
    @State private var apiKeyTestResult: String?
    @State private var apiKeyTestSucceeded: Bool?

    var body: some View {
        TabView {
            generalSettings
                .tabItem {
                    Label("一般", systemImage: "switch.2")
                }

            outputSettings
                .tabItem {
                    Label("輸出", systemImage: "folder")
                }

            runtimeSettings
                .tabItem {
                    Label("Runtime", systemImage: "cpu")
                }

            storageSettings
                .tabItem {
                    Label("儲存", systemImage: "externaldrive")
                }
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .confirmationDialog(
            "重設 record-to-text？",
            isPresented: Binding(
                get: { resetChoice != nil },
                set: { if !$0 { resetChoice = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let resetChoice {
                Button(resetChoice.buttonTitle, role: .destructive) {
                    viewModel.resetSettings(keepGlossaries: resetChoice == .keepGlossaries)
                    self.resetChoice = nil
                }
            }
            Button("取消", role: .cancel) {
                resetChoice = nil
            }
        } message: {
            Text(resetChoice?.message ?? "")
        }
    }

    private var generalSettings: some View {
        Form {
            Section("關於此 App") {
                LabeledContent("版本") {
                    Text(appVersionLabel)
                        .textSelection(.enabled)
                }
                LabeledContent("建置") {
                    Text(appBuildLabel)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("長音預切") {
                    Text(segmentPolicyLabel)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("每段 token 上限") {
                    Text("\(defaultMaximumTokens)")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("若「長音預切」不是 20 分鐘，代表你開的不是含此改動的建置。請關閉所有視窗後改開專案 dist/record-to-text.app。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("工作流程") {
                Text("加入的檔案會先進入佇列，需按「開始轉文字」才會執行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(
                    "完成後在 Finder 顯示",
                    isOn: setting(\.revealInFinderWhenCompleted)
                )
                Toggle(
                    "完成後打開文字檔",
                    isOn: setting(\.openTextWhenCompleted)
                )
                Toggle(
                    "保留 Qwen 原始逐字稿",
                    isOn: setting(\.keepRawTranscript)
                )
            }

            Section("通知") {
                Toggle(
                    "顯示完成通知",
                    isOn: Binding(
                        get: { viewModel.settings.showNotificationWhenCompleted },
                        set: { viewModel.setNotificationPreference($0) }
                    )
                )
                Text("第一次開啟時，macOS 會詢問通知權限。未授權不影響轉錄。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var appVersionLabel: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "—"
        return short
    }

    private var appBuildLabel: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let path = Bundle.main.bundlePath
        return "\(build) · \(path)"
    }

    private var segmentPolicyLabel: String {
        let seconds = Int(AudioSegmentPlanner.productionMaximumDuration)
        let minutes = seconds / 60
        return "每段最長 \(minutes) 分鐘（\(seconds) 秒）"
    }

    private var defaultMaximumTokens: Int {
        // Keep in sync with ASRRequest default.
        16_384
    }

    private var outputSettings: some View {
        Form {
            Section("輸出位置") {
                Picker(
                    "模式",
                    selection: setting(\.outputLocationMode)
                ) {
                    ForEach(OutputLocationMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                if viewModel.settings.outputLocationMode == .fixedDirectory {
                    LabeledContent("預設資料夾") {
                        HStack(spacing: 8) {
                            Text(viewModel.settings.defaultOutputDirectory)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 320, alignment: .trailing)
                            Button("選擇…") {
                                viewModel.chooseDefaultOutputDirectory()
                            }
                        }
                    }
                }

                Text(outputModeHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("檔名格式") {
                TextField(
                    "檔名後綴",
                    text: Binding(
                        get: {
                            viewModel.settings.outputFilenameSuffix
                                ?? OutputNameBuilder.defaultFinalSuffix
                        },
                        set: { newValue in
                            viewModel.setSetting(
                                \.outputFilenameSuffix,
                                to: OutputNameBuilder.sanitizedSuffix(
                                    newValue,
                                    fallback: OutputNameBuilder.defaultFinalSuffix
                                )
                            )
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)

                LabeledContent("預覽") {
                    Text(
                        OutputNameBuilder.previewFileName(
                            suffix: viewModel.settings.resolvedOutputFilenameSuffix
                        )
                    )
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }

                Text(
                    "例：錄音.m4a → 錄音\(viewModel.settings.resolvedOutputFilenameSuffix).txt"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("檔案編碼") {
                LabeledContent("格式") {
                    Text("UTF-8・LF・無 BOM")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var runtimeSettings: some View {
        Form {
            Section("轉錄引擎管道 (ASR Backend)") {
                Picker(
                    "管道模式",
                    selection: Binding(
                        get: { viewModel.settings.backendType },
                        set: {
                            viewModel.setSetting(\.backendType, to: $0)
                            viewModel.refreshEnvironment()
                        }
                    )
                ) {
                    ForEach(ASRBackendType.allCases, id: \.self) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.segmented)

                if viewModel.settings.backendType == .googleAIStudio {
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField(
                            "Google AI Studio API Key",
                            text: Binding(
                                get: { viewModel.settings.googleAIStudioAPIKey ?? "" },
                                set: { viewModel.setSetting(\.googleAIStudioAPIKey, to: $0.isEmpty ? nil : $0) }
                            ),
                            prompt: Text("請貼上 Gemini API Key (AIza...)")
                        )
                        .textFieldStyle(.roundedBorder)

                        HStack {
                            Button("測試 API Key 連線") {
                                testGoogleAIStudioAPIKey()
                            }
                            .disabled(isTestingAPIKey || (viewModel.settings.googleAIStudioAPIKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            if isTestingAPIKey {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            if let result = apiKeyTestResult {
                                Text(result)
                                    .font(.caption)
                                    .foregroundStyle(apiKeyTestSucceeded == true ? .green : .red)
                            }
                        }
                    }

                    Picker(
                        "模型選擇",
                        selection: Binding(
                            get: {
                                if GeminiModelDescriptor.presetModels.contains(where: { $0.id == viewModel.settings.googleAIStudioModelID }) {
                                    return viewModel.settings.googleAIStudioModelID
                                }
                                return "custom"
                            },
                            set: { newValue in
                                if newValue != "custom" {
                                    viewModel.setSetting(\.googleAIStudioModelID, to: newValue)
                                }
                            }
                        )
                    ) {
                        ForEach(GeminiModelDescriptor.presetModels) { preset in
                            Text(preset.displayName).tag(preset.id)
                        }
                        Text("自訂模型 ID…").tag("custom")
                    }

                    if !GeminiModelDescriptor.presetModels.contains(where: { $0.id == viewModel.settings.googleAIStudioModelID }) {
                        TextField(
                            "自訂模型 ID (Model ID)",
                            text: Binding(
                                get: { viewModel.settings.googleAIStudioModelID },
                                set: { viewModel.setSetting(\.googleAIStudioModelID, to: $0.isEmpty ? "gemini-3.7-flash" : $0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    if let selectedPreset = GeminiModelDescriptor.presetModels.first(where: { $0.id == viewModel.settings.googleAIStudioModelID }) {
                        Text(selectedPreset.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Google AI Studio API 採用標準 Gemini API Key，免裝 gcloud、免設定 GCP 專案。超長錄音自動切片上傳並無縫合併，輸出台灣繁體中文。所有設定即時自動儲存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if viewModel.settings.backendType == .vertexAI {
                    TextField(
                        "GCP Project ID",
                        text: Binding(
                            get: { viewModel.settings.vertexAIProjectID ?? "" },
                            set: { viewModel.setSetting(\.vertexAIProjectID, to: $0.isEmpty ? nil : $0) }
                        ),
                        prompt: Text("留空則自動讀取 gcloud 當前專案")
                    )
                    .textFieldStyle(.roundedBorder)

                    TextField(
                        "GCP 區域 (Location)",
                        text: Binding(
                            get: { viewModel.settings.vertexAILocation },
                            set: { viewModel.setSetting(\.vertexAILocation, to: $0.isEmpty ? "global" : $0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    TextField(
                        "GCS Bucket 名稱（可選）",
                        text: Binding(
                            get: { viewModel.settings.vertexAIGCSBucket ?? "" },
                            set: { viewModel.setSetting(\.vertexAIGCSBucket, to: $0.isEmpty ? nil : $0) }
                        ),
                        prompt: Text("例：my-transcription-bucket（音訊分離上傳用）")
                    )
                    .textFieldStyle(.roundedBorder)

                    Picker(
                        "模型選擇",
                        selection: Binding(
                            get: {
                                if GeminiModelDescriptor.presetModels.contains(where: { $0.id == viewModel.settings.vertexAIModelID }) {
                                    return viewModel.settings.vertexAIModelID
                                }
                                return "custom"
                            },
                            set: { newValue in
                                if newValue != "custom" {
                                    viewModel.setSetting(\.vertexAIModelID, to: newValue)
                                }
                            }
                        )
                    ) {
                        ForEach(GeminiModelDescriptor.presetModels) { preset in
                            Text(preset.displayName).tag(preset.id)
                        }
                        Text("自訂模型 ID…").tag("custom")
                    }

                    if !GeminiModelDescriptor.presetModels.contains(where: { $0.id == viewModel.settings.vertexAIModelID }) {
                        TextField(
                            "自訂模型 ID (Model ID)",
                            text: Binding(
                                get: { viewModel.settings.vertexAIModelID },
                                set: { viewModel.setSetting(\.vertexAIModelID, to: $0.isEmpty ? "gemini-3.7-flash" : $0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    if let selectedPreset = GeminiModelDescriptor.presetModels.first(where: { $0.id == viewModel.settings.vertexAIModelID }) {
                        Text(selectedPreset.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    TextField(
                        "自訂 gcloud 路徑",
                        text: Binding(
                            get: { viewModel.settings.customGCloudPath ?? "" },
                            set: {
                                viewModel.setSetting(\.customGCloudPath, to: $0.isEmpty ? nil : $0)
                                viewModel.refreshEnvironment()
                            }
                        ),
                        prompt: Text("留空則自動搜尋 /opt/homebrew/bin/gcloud 等標準路徑")
                    )
                    .textFieldStyle(.roundedBorder)

                    Text("Vertex AI 使用本機 `gcloud` 認證與 GCP 專案。所有設定皆會即時自動儲存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("執行環境檢查…") {
                    viewModel.refreshEnvironment()
                    viewModel.isEnvironmentPresented = true
                }
            }
        }
        .formStyle(.grouped)
    }

    private var storageSettings: some View {
        Form {
            Section("最近工作") {
                Stepper(
                    "保留 \(viewModel.settings.recentJobLimit) 筆",
                    value: setting(\.recentJobLimit),
                    in: 0...50
                )

                Button("清除已完成與失敗的記錄") {
                    viewModel.clearRecentJobs()
                }
                .disabled(
                    viewModel.recentJobs.isEmpty
                        && !viewModel.jobs.contains(where: { $0.stage.isTerminal })
                )

                Text("清除記錄不會刪除錄音、文字檔或失敗時保留的 WAV。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("App 資料") {
                LabeledContent("位置") {
                    Text(viewModel.applicationSupportURL.path)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button("在 Finder 顯示") {
                    viewModel.revealApplicationSupport()
                }
            }

            Section("重設") {
                Button("重設設定，保留詞庫…") {
                    resetChoice = .keepGlossaries
                }
                Button("重設設定與詞庫…", role: .destructive) {
                    resetChoice = .everything
                }
            }
        }
        .formStyle(.grouped)
    }

    private var outputModeHelp: String {
        switch viewModel.settings.outputLocationMode {
        case .fixedDirectory:
            return "所有工作輸出到同一個資料夾。"
        case .sameAsSource:
            return "每個文字檔會放在原始錄音旁邊。"
        case .askEveryTime:
            return "每次加入一批錄音時選擇一次輸出資料夾。"
        }
    }

    private func setting<Value>(
        _ keyPath: WritableKeyPath<AppSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { viewModel.settings[keyPath: keyPath] },
            set: { viewModel.setSetting(keyPath, to: $0) }
        )
    }

    private func optionalStringSetting(
        _ keyPath: WritableKeyPath<AppSettings, String?>
    ) -> Binding<String> {
        Binding(
            get: { viewModel.settings[keyPath: keyPath] ?? "" },
            set: {
                let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                viewModel.setSetting(keyPath, to: value.isEmpty ? nil : value)
            }
        )
    }

    private func testGoogleAIStudioAPIKey() {
        guard let key = viewModel.settings.googleAIStudioAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            apiKeyTestResult = "請先輸入 API Key"
            apiKeyTestSucceeded = false
            return
        }

        isTestingAPIKey = true
        apiKeyTestResult = nil
        apiKeyTestSucceeded = nil

        Task {
            let backend = GoogleAIStudioBackend()
            do {
                _ = try await backend.validateAPIKey(key)
                await MainActor.run {
                    isTestingAPIKey = false
                    apiKeyTestResult = "✅ 連線成功！API Key 有效。"
                    apiKeyTestSucceeded = true
                }
            } catch {
                await MainActor.run {
                    isTestingAPIKey = false
                    apiKeyTestResult = "❌ 驗證失敗：\(error.localizedDescription)"
                    apiKeyTestSucceeded = false
                }
            }
        }
    }
}

private enum ResetChoice {
    case keepGlossaries
    case everything

    var buttonTitle: String {
        switch self {
        case .keepGlossaries:
            return "重設設定"
        case .everything:
            return "重設設定與詞庫"
        }
    }

    var message: String {
        switch self {
        case .keepGlossaries:
            return "一般、輸出與 Runtime 設定會回到預設值，詞庫會保留。"
        case .everything:
            return "設定與所有詞庫都會清除。既有錄音與文字檔不受影響。"
        }
    }
}

import RecordToTextCore
import SwiftUI

enum GoogleAIStudioAPIKeyDraftPolicy {
    static func shouldDisableSave(
        normalizedDraft: String?,
        normalizedInMemoryAPIKey: String?,
        storageState: GoogleAIStudioCredentialStorageState,
        hasPendingMigration: Bool
    ) -> Bool {
        guard let normalizedDraft else {
            return true
        }
        return normalizedDraft == normalizedInMemoryAPIKey
            && storageState == .stored
            && !hasPendingMigration
    }

    static func afterClearAttempt(
        succeeded: Bool,
        attemptedDraft: String,
        inMemoryAPIKey: String?
    ) -> String {
        guard !succeeded else {
            return ""
        }
        return inMemoryAPIKey ?? attemptedDraft
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var resetChoice: ResetChoice?
    @State private var isTestingAPIKey = false
    @State private var apiKeyTestResult: String?
    @State private var apiKeyTestSucceeded: Bool?
    @State private var apiKeyDraft = ""

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
        .onAppear {
            apiKeyDraft = viewModel.settings.googleAIStudioAPIKey ?? ""
        }
        .onChange(of: viewModel.settings.googleAIStudioAPIKey) { _, newValue in
            apiKeyDraft = newValue ?? ""
        }
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
                    apiKeyDraft = viewModel.settings.googleAIStudioAPIKey ?? ""
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

                if viewModel.settings.backendType == .localQwen {
                    Text("本機模式：錄音與模型皆留在這台 Mac，不上雲。需要先下載 Qwen ASR 模型。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if viewModel.settings.backendType == .googleAIStudio {
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField(
                            "Google AI Studio API Key",
                            text: $apiKeyDraft,
                            prompt: Text("請貼上 Gemini API Key (AIza...)")
                        )
                        .textFieldStyle(.roundedBorder)

                        HStack {
                            Button("儲存到 Keychain") {
                                viewModel.setGoogleAIStudioAPIKey(apiKeyDraft)
                                apiKeyTestResult = nil
                                apiKeyTestSucceeded = nil
                            }
                            .disabled(
                                GoogleAIStudioAPIKeyDraftPolicy.shouldDisableSave(
                                    normalizedDraft: normalizedAPIKeyDraft,
                                    normalizedInMemoryAPIKey: normalizedInMemoryAPIKey,
                                    storageState: viewModel
                                        .googleAIStudioCredentialStorageState,
                                    hasPendingMigration: viewModel
                                        .hasPendingGoogleAIStudioCredentialMigration
                                )
                            )

                            Button("測試 API Key 連線") {
                                testGoogleAIStudioAPIKey()
                            }
                            .disabled(isTestingAPIKey || normalizedAPIKeyDraft == nil)

                            Button("清除", role: .destructive) {
                                let attemptedDraft = apiKeyDraft
                                let succeeded = viewModel.setGoogleAIStudioAPIKey(nil)
                                apiKeyDraft = GoogleAIStudioAPIKeyDraftPolicy
                                    .afterClearAttempt(
                                        succeeded: succeeded,
                                        attemptedDraft: attemptedDraft,
                                        inMemoryAPIKey: viewModel.settings
                                            .googleAIStudioAPIKey
                                    )
                                apiKeyTestResult = nil
                                apiKeyTestSucceeded = nil
                            }
                            .disabled(
                                viewModel.googleAIStudioCredentialStorageState
                                    == .absent
                                    && normalizedInMemoryAPIKey == nil
                                    && normalizedAPIKeyDraft == nil
                            )

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

                        Text(viewModel.googleAIStudioCredentialStorageDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                    Text("Google AI Studio API 採用標準 Gemini API Key，免裝 gcloud、免設定 GCP 專案。長錄音會自動分段上傳並依順序合併，輸出台灣繁體中文。其餘設定會自動儲存；API Key 需按「儲存到 Keychain」。")
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

                    Toggle(
                        "附加內容摘要（輸出不再是純逐字稿）",
                        isOn: setting(\.vertexAIIncludeSummary)
                    )
                    Text("預設關閉。開啟後，Vertex AI 會在逐字稿後附加摘要；若要保留純原始逐字稿，請維持關閉。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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

                if viewModel.settings.backendType == .localQwen {
                    localQwenModelSettings
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

    private var localQwenModelSettings: some View {
        Group {
            localQwenRuntimeSettings

            Divider()

            Picker(
                "模型",
                selection: Binding(
                    get: { viewModel.settings.selectedModelID },
                    set: { viewModel.setSelectedModelID($0) }
                )
            ) {
                ForEach(viewModel.availableModels) { model in
                    Text(model.displayName).tag(model.id)
                }
                if !viewModel.availableModels.contains(where: {
                    $0.id == viewModel.settings.selectedModelID
                }) {
                    Text(viewModel.settings.selectedModelID)
                        .tag(viewModel.settings.selectedModelID)
                }
            }
            .disabled(viewModel.modelDownloadPhase.isBusy)

            HStack(spacing: 10) {
                Button(viewModel.modelDownloadButtonTitle) {
                    viewModel.downloadSelectedModel()
                }
                .disabled(!viewModel.canDownloadSelectedModel)

                if viewModel.modelDownloadPhase.isBusy {
                    ProgressView()
                        .controlSize(.small)
                    Button("取消") {
                        viewModel.cancelModelDownload()
                    }
                } else if viewModel.isSelectedModelCached {
                    Label("App 模型目錄已就緒", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if viewModel.isSelectedModelInDefaultHFCache {
                    Label("本機 Hugging Face cache 可匯入", systemImage: "externaldrive.fill.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("模型 ID") {
                Text(viewModel.settings.selectedModelID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }

            if let detail = viewModel.selectedModelDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !viewModel.modelDownloadProgressLine.isEmpty {
                Text(viewModel.modelDownloadProgressLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }

            switch viewModel.modelDownloadPhase {
            case let .succeeded(message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.green)
            case let .failed(message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            case .idle, .importingLocal, .downloading:
                EmptyView()
            }

            Text("下載位置：App 的 Models 目錄。若 ~/.cache/huggingface 已有同模型，會優先本機匯入，避免重複下載。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if CPUArchitecture.current == .x86_64 {
                Label(
                    "Intel CPU backend 尚未完成實機驗證，目前為 Experimental。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else if viewModel.settings.selectedModelID
                == ASRModelDescriptor.appleSiliconBF16.id
            {
                Text("BF16 體積較大，並需要更多統一記憶體。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            viewModel.refreshSelectedModelCacheStatus()
        }
    }

    private var localQwenRuntimeSettings: some View {
        Group {
            Toggle(
                "使用這台 Mac 的開發 Runtime",
                isOn: Binding(
                    get: { viewModel.settings.developerMode },
                    set: { enabled in
                        viewModel.setSetting(\.developerMode, to: enabled)
                        viewModel.refreshEnvironment()
                    }
                )
            )

            if viewModel.settings.developerMode {
                Text("你已明確允許 App 使用這台 Mac 上的工具。App 會檢查檔案是否可用，但不會把開發工具誤標成已簽章的受管理 Runtime。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField(
                    "Python 執行檔",
                    text: runtimePathSetting(\.customPythonPath),
                    prompt: Text(developerRuntimeDiscovery.python.path)
                )
                .textFieldStyle(.roundedBorder)

                LabeledContent("OpenCC（自動偵測）") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(developerRuntimeDiscovery.openCC.path)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Text(
                            developerRuntimeDiscovery.openCCWasDetected
                                ? "已找到"
                                : "未找到；請先安裝 Homebrew opencc"
                        )
                        .font(.caption2)
                        .foregroundStyle(
                            developerRuntimeDiscovery.openCCWasDetected
                                ? Color.green
                                : Color.red
                        )
                    }
                }

                TextField(
                    "自訂 Qwen Helper 路徑",
                    text: runtimePathSetting(\.customHelperPath),
                    prompt: Text("留空使用 App 內建 Helper")
                )
                .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    Button("重新自動偵測") {
                        useAutoDetectedDeveloperRuntime()
                    }

                    Text(
                        developerRuntimeDiscovery.pythonWasDetected
                            ? "已找到 Python：\(developerRuntimeDiscovery.python.path)"
                            : "未找到專用 Python；預期位置：\(developerRuntimeDiscovery.python.path)"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        developerRuntimeDiscovery.pythonWasDetected
                            ? Color.secondary
                            : Color.red
                    )
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                }
            } else {
                Label(
                    "受管理 Runtime 必須通過完整性與簽章驗證才會執行；僅有檔案存在並不算可信。若尚未安裝受信任 Runtime，可明確改用這台 Mac 的開發環境。",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.orange)

                Button("改用自動偵測的開發 Runtime") {
                    useAutoDetectedDeveloperRuntime()
                }
            }
        }
    }

    private var developerRuntimeDiscovery: DeveloperRuntimeDiscovery {
        RuntimeEnvironment.discoverDeveloperRuntime()
    }

    private func runtimePathSetting(
        _ keyPath: WritableKeyPath<AppSettings, String?>
    ) -> Binding<String> {
        Binding(
            get: { viewModel.settings[keyPath: keyPath] ?? "" },
            set: { newValue in
                let normalized = newValue.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                viewModel.setSetting(
                    keyPath,
                    to: normalized.isEmpty ? nil : normalized
                )
                viewModel.refreshEnvironment()
            }
        )
    }

    private func useAutoDetectedDeveloperRuntime() {
        viewModel.setSetting(\.customPythonPath, to: nil)
        viewModel.setSetting(\.customHelperPath, to: nil)
        viewModel.setSetting(\.developerMode, to: true)
        viewModel.refreshEnvironment()
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
        guard let key = normalizedAPIKeyDraft else {
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

    private var normalizedAPIKeyDraft: String? {
        normalizedAPIKey(apiKeyDraft)
    }

    private var normalizedInMemoryAPIKey: String? {
        normalizedAPIKey(viewModel.settings.googleAIStudioAPIKey ?? "")
    }

    private func normalizedAPIKey(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
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

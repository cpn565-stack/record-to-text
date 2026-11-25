import AppKit
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
    @Environment(\.colorSchemeContrast) private var contrast

    private var supportedThinkingLevels: [GeminiThinkingLevel] {
        GeminiGenerationConfig.supportedThinkingLevels(modelID: viewModel.settings.selectedGeminiModelID)
    }

    @State private var resetChoice: ResetChoice?
    @State private var isLocalEnvironmentPresented = false
    @State private var isLocalUnsuccessfulCleanupPresented = false

    // Google AI Studio credential & connection test state
    @State private var apiKeyDraft = ""
    @State private var isTestingAPIKey = false
    @State private var apiKeyTestResult: String?
    @State private var apiKeyTestSucceeded: Bool?
    @State private var apiKeyTestTask: Task<Void, Never>?

    // Vertex AI draft & connection test state
    @State private var vertexProjectDraft = ""
    @State private var vertexLocationDraft = "global"
    @State private var vertexBucketDraft = ""
    @State private var customGCloudPathDraft = ""
    @State private var isTestingVertexAuth = false
    @State private var vertexAuthTestResult: String?
    @State private var vertexAuthTestSucceeded: Bool?
    @State private var vertexAuthTestTask: Task<Void, Never>?
    @State private var environmentDebounceTask: Task<Void, Never>?

    // Local Qwen developer runtime drafts & discovery
    @State private var customPythonPathDraft = ""
    @State private var customHelperPathDraft = ""
    @State private var developerRuntimeDiscovery = DeveloperRuntimeDiscovery(
        python: URL(fileURLWithPath: "/usr/bin/python3"),
        openCC: URL(fileURLWithPath: "/opt/homebrew/bin/opencc"),
        pythonWasDetected: false,
        openCCWasDetected: false
    )

    // Output suffix draft
    @State private var outputSuffixDraft = ""

    // Copy feedback states
    @State private var copiedAppSupportPath = false
    @State private var copiedBundlePath = false

    var body: some View {
        TabView {
            generalSettings
                .tabItem {
                    Label("一般", systemImage: "switch.2")
                }

            engineSettings
                .tabItem {
                    Label("轉錄引擎", systemImage: "cpu")
                }

            outputSettings
                .tabItem {
                    Label("輸出", systemImage: "folder")
                }

            dataAndAboutSettings
                .tabItem {
                    Label("資料與關於", systemImage: "externaldrive")
                }
        }
        .padding(AppSpacing.xl)
        .frame(width: 680)
        .frame(minHeight: 500, idealHeight: 580)
        .onAppear(perform: syncAllDraftsFromSettings)
        .onDisappear {
            commitPendingDrafts()
            apiKeyTestTask?.cancel()
            vertexAuthTestTask?.cancel()
            environmentDebounceTask?.cancel()
        }
        .onChange(of: viewModel.settings.googleAIStudioAPIKey) { _, newValue in
            apiKeyDraft = newValue ?? ""
        }
        .onChange(of: viewModel.settings.vertexAIProjectID) { _, newValue in
            let next = newValue ?? ""
            if vertexProjectDraft.trimmingCharacters(in: .whitespacesAndNewlines) != next {
                vertexProjectDraft = next
            }
        }
        .onChange(of: viewModel.settings.vertexAILocation) { _, newValue in
            if vertexLocationDraft.trimmingCharacters(in: .whitespacesAndNewlines) != newValue {
                vertexLocationDraft = newValue
            }
        }
        .onChange(of: viewModel.settings.vertexAIGCSBucket) { _, newValue in
            let next = newValue ?? ""
            if normalizedBucketString(vertexBucketDraft) != next {
                vertexBucketDraft = next
            }
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
                    Task {
                        await viewModel.resetSettings(keepGlossaries: resetChoice == .keepGlossaries)
                        syncAllDraftsFromSettings()
                        self.resetChoice = nil
                    }
                }
            }
            Button("取消", role: .cancel) {
                resetChoice = nil
            }
        } message: {
            Text(resetChoice?.message ?? "")
        }
        .sheet(isPresented: $isLocalEnvironmentPresented) {
            EnvironmentCheckView(viewModel: viewModel, showsOpenSettingsButton: false)
                .tint(AppColors.accent)
        }
        .confirmationDialog(
            "一鍵清除未成功項目與殘留檔？",
            isPresented: $isLocalUnsuccessfulCleanupPresented,
            titleVisibility: .visible
        ) {
            Button("一鍵清除", role: .destructive) {
                Task { await viewModel.cleanUpUnsuccessfulJobsAndResidualFiles() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("將一併清除所有「失敗、已取消、被中斷」工作紀錄，以及系統暫存與 Temp-Recovery 內的全部殘留目錄。所有「完成」與「完成（含缺口）」紀錄、已輸出的 .txt 文字稿，以及原始錄音檔皆會完整保留。")
        }
    }

    // MARK: - Tab 1: 一般 (General)

    private var generalSettings: some View {
        Form {
            Section("工作流程") {
                Text("加入的錄音會先進入等待中佇列，按下「開始轉文字」才會開始執行。")
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
                Text("首次開啟時 macOS 會詢問通知權限；未授權不影響轉錄流程。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Tab 2: 轉錄引擎 (Transcription Engine)

    private var engineSettings: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: 6) {
                BackendSelectionRow(viewModel: viewModel)

                Text("引擎與模型變更會套用至新錄音與待轉工作；執行中與檢查點續跑工作沿用原設定。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }

            Form {
                switch viewModel.settings.backendType {
                case .googleAIStudio:
                    googleAIStudioCredentialsSection
                    cloudModelAndThinkingSection(modelBinding: setting(\.googleAIStudioModelID), isVertex: false)
                    cloudSegmentationAndPostprocessingSection(isVertex: false)

                case .vertexAI:
                    vertexAICredentialsSection
                    cloudModelAndThinkingSection(modelBinding: setting(\.vertexAIModelID), isVertex: true)
                    cloudSegmentationAndPostprocessingSection(isVertex: true)

                case .localQwen:
                    localQwenRuntimeSection
                    localQwenModelSection
                    localQwenSegmentationSection
                }

                Section {
                    HStack {
                        Button("執行環境檢查…") {
                            commitPendingDrafts()
                            viewModel.refreshEnvironment()
                            isLocalEnvironmentPresented = true
                        }
                        Spacer()
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private var googleAIStudioCredentialsSection: some View {
        Section("連線與憑證") {
            SecureField(
                "Gemini API Key",
                text: $apiKeyDraft,
                prompt: Text("請貼上 Google AI Studio API Key (AIza...)")
            )
            .textFieldStyle(.roundedBorder)
            .disabled(viewModel.isGoogleAIStudioCredentialLoading || viewModel.isGoogleAIStudioCredentialSaving)

            HStack(spacing: AppSpacing.sm) {
                Button("儲存到 Keychain") {
                    Task { await viewModel.setGoogleAIStudioAPIKey(apiKeyDraft) }
                    apiKeyTestResult = nil
                    apiKeyTestSucceeded = nil
                }
                .disabled(
                    viewModel.isGoogleAIStudioCredentialLoading
                        || viewModel.isGoogleAIStudioCredentialSaving
                        || GoogleAIStudioAPIKeyDraftPolicy.shouldDisableSave(
                            normalizedDraft: normalizedAPIKeyDraft,
                            normalizedInMemoryAPIKey: normalizedInMemoryAPIKey,
                            storageState: viewModel.googleAIStudioCredentialStorageState,
                            hasPendingMigration: viewModel.hasPendingGoogleAIStudioCredentialMigration
                        )
                )

                Button("測試連線") {
                    testGoogleAIStudioAPIKey()
                }
                .disabled(viewModel.isGoogleAIStudioCredentialLoading || isTestingAPIKey || normalizedAPIKeyDraft == nil)

                Button("清除", role: .destructive) {
                    Task {
                        let attemptedDraft = apiKeyDraft
                        let succeeded = await viewModel.setGoogleAIStudioAPIKey(nil)
                        apiKeyDraft = GoogleAIStudioAPIKeyDraftPolicy.afterClearAttempt(
                            succeeded: succeeded,
                            attemptedDraft: attemptedDraft,
                            inMemoryAPIKey: viewModel.settings.googleAIStudioAPIKey
                        )
                        apiKeyTestResult = nil
                        apiKeyTestSucceeded = nil
                    }
                }
                .disabled(
                    viewModel.isGoogleAIStudioCredentialLoading || (
                        viewModel.googleAIStudioCredentialStorageState == .absent
                            && normalizedInMemoryAPIKey == nil
                            && normalizedAPIKeyDraft == nil
                    )
                )

                if isTestingAPIKey {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let result = apiKeyTestResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(apiKeyTestSucceeded == true ? AppColors.success : AppColors.danger)
            }

            Text(viewModel.googleAIStudioCredentialStorageDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var vertexAICredentialsSection: some View {
        Section("連線與憑證") {
            TextField(
                "GCP Project ID",
                text: $vertexProjectDraft,
                prompt: Text("留空則自動讀取 gcloud 當前專案")
            )
            .textFieldStyle(.roundedBorder)
            .onChange(of: vertexProjectDraft) { _, newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                viewModel.setSetting(\.vertexAIProjectID, to: trimmed.isEmpty ? nil : trimmed)
            }

            TextField(
                "GCP 區域 (Location)",
                text: $vertexLocationDraft,
                prompt: Text("global")
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit(commitVertexLocationDraft)
            .onChange(of: vertexLocationDraft) { _, newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    viewModel.setSetting(\.vertexAILocation, to: trimmed)
                }
            }

            TextField(
                "GCS Bucket 名稱（可選）",
                text: $vertexBucketDraft,
                prompt: Text("例：my-transcription-bucket（超過 20MB 音訊分流上傳用）")
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit(commitVertexBucketDraft)
            .onChange(of: vertexBucketDraft) { _, newValue in
                let clean = normalizedBucketString(newValue)
                viewModel.setSetting(\.vertexAIGCSBucket, to: clean.isEmpty ? nil : clean)
            }

            TextField(
                "自訂 gcloud 路徑",
                text: $customGCloudPathDraft,
                prompt: Text("留空則自動搜尋 /opt/homebrew/bin/gcloud 等標準路徑")
            )
            .textFieldStyle(.roundedBorder)
            .onChange(of: customGCloudPathDraft) { _, newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                viewModel.setSetting(\.customGCloudPath, to: trimmed.isEmpty ? nil : trimmed)
                scheduleDebouncedEnvironmentRefresh()
            }

            HStack(spacing: AppSpacing.sm) {
                Button("測試 gcloud 與專案連線") {
                    testVertexAIAuthentication()
                }
                .disabled(isTestingVertexAuth)

                if isTestingVertexAuth {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let vertexResult = vertexAuthTestResult {
                Text(vertexResult)
                    .font(.caption)
                    .foregroundStyle(vertexAuthTestSucceeded == true ? AppColors.success : AppColors.danger)
            }
        }
    }

    private func cloudModelAndThinkingSection(
        modelBinding: Binding<String>,
        isVertex: Bool
    ) -> some View {
        Section("模型與思考強度") {
            GeminiModelPicker(modelID: modelBinding)

            if isVertex, viewModel.settings.vertexAIModelID == "gemini-4-neon" {
                Text("Neon 支援 global、us、eu 區域；請確認上方 Location 與專案權限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isVertex, viewModel.settings.vertexAIModelID == "gemini-4-hydrogen" {
                Text("Hydrogen 支援 global、us、eu 區域；請確認上方 Location 與專案權限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !supportedThinkingLevels.isEmpty {
                Picker(
                    "Gemini 思考強度",
                    selection: setting(\.geminiThinkingLevel)
                ) {
                    ForEach(supportedThinkingLevels, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .accessibilityIdentifier("gemini-thinking-level-picker")
            } else {
                Text("此自訂模型尚無已確認的思考強度選項，不會傳送思考設定。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("思考強度說明") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("• 各模型分別記住思考強度（Neon 預設高、Hydrogen 預設極高）；較高強度通常更耗時並消耗更多輸出 token。")
                    Text("• 不自動切換至其他模型，避免同一份長錄音混用不同模型。")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }

    private func cloudSegmentationAndPostprocessingSection(isVertex: Bool) -> some View {
        let activeModelID = isVertex
            ? viewModel.settings.vertexAIModelID
            : viewModel.settings.googleAIStudioModelID
        let maxTokens = GeminiGenerationConfig.transcriptionOutputTokens(modelID: activeModelID)

        return Section("分段與後處理") {
            Toggle(
                "在單段上限前優先尋找靜音切點",
                isOn: setting(\.silenceAwareCloudSegmentation)
            )
            Text("單段上限 20 分鐘；開啟後會掃描上限前 30 秒尋找自然停頓切分，找不到則安全硬切。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isVertex {
                Toggle(
                    "附加內容摘要（輸出不再是純逐字稿）",
                    isOn: setting(\.vertexAIIncludeSummary)
                )
            }

            LabeledContent("雲端單段輸出上限") {
                Text("\(maxTokens.formatted()) tokens")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text("雲端最終稿會經本機 OpenCC（s2tw）統一為台灣繁體字形，保留講者原始用詞。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Local Qwen Sections

    private var localQwenRuntimeSection: some View {
        Section("本機 Runtime 環境") {
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
                TextField(
                    "Python 執行檔",
                    text: $customPythonPathDraft,
                    prompt: Text(developerRuntimeDiscovery.python.path)
                )
                .textFieldStyle(.roundedBorder)
                .onChange(of: customPythonPathDraft) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    viewModel.setSetting(\.customPythonPath, to: trimmed.isEmpty ? nil : trimmed)
                    scheduleDebouncedEnvironmentRefresh()
                }

                TextField(
                    "自訂 Qwen Helper 路徑",
                    text: $customHelperPathDraft,
                    prompt: Text("留空使用 App 內建 Helper")
                )
                .textFieldStyle(.roundedBorder)
                .onChange(of: customHelperPathDraft) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    viewModel.setSetting(\.customHelperPath, to: trimmed.isEmpty ? nil : trimmed)
                    scheduleDebouncedEnvironmentRefresh()
                }

                LabeledContent("OpenCC（自動偵測）") {
                    HStack(spacing: 6) {
                        StatusBadge(
                            text: developerRuntimeDiscovery.openCCWasDetected ? "已找到" : "未找到",
                            color: developerRuntimeDiscovery.openCCWasDetected ? AppColors.success : AppColors.danger
                        )
                        Text(developerRuntimeDiscovery.openCC.path)
                            .font(AppTypography.monoDetail)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                HStack(spacing: AppSpacing.sm) {
                    Button("重新自動偵測") {
                        useAutoDetectedDeveloperRuntime()
                    }
                    Text(
                        developerRuntimeDiscovery.pythonWasDetected
                            ? "已找到 Python：\(developerRuntimeDiscovery.python.path)"
                            : "未找到專用 Python（預期：\(developerRuntimeDiscovery.python.path)）"
                    )
                    .font(.caption)
                    .foregroundStyle(developerRuntimeDiscovery.pythonWasDetected ? Color.secondary : AppColors.danger)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            } else {
                Label(
                    "受管理 Runtime 須通過簽章與完整性驗證才會執行；亦可改用本機開發環境。",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(AppColors.warning)

                Button("改用自動偵測的開發 Runtime") {
                    useAutoDetectedDeveloperRuntime()
                }
            }
        }
        .onAppear(perform: refreshDeveloperRuntimeDiscovery)
    }

    private var localQwenModelSection: some View {
        Section("模型與快取") {
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

            HStack(spacing: AppSpacing.sm) {
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
                } else if viewModel.isModelCacheStatusRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else if viewModel.isSelectedModelCached {
                    Label("App 模型目錄已就緒", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(AppColors.success)
                } else if viewModel.isSelectedModelInDefaultHFCache {
                    Label("可從 ~/.cache/huggingface 直接匯入", systemImage: "externaldrive.fill.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("模型 ID") {
                Text(viewModel.settings.selectedModelID)
                    .font(AppTypography.monoDetail)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let detail = viewModel.selectedModelDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !viewModel.modelDownloadProgressLine.isEmpty {
                Text(viewModel.modelDownloadProgressLine)
                    .font(AppTypography.monoDetail)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }

            switch viewModel.modelDownloadPhase {
            case let .succeeded(message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AppColors.success)
            case let .failed(message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AppColors.danger)
                    .textSelection(.enabled)
            case .idle, .importingLocal, .downloading:
                EmptyView()
            }

            if CPUArchitecture.current == .x86_64 {
                Label(
                    "Intel CPU backend 尚未完成實機驗證，目前為 Experimental。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(AppColors.warning)
            }
        }
        .onAppear {
            viewModel.refreshSelectedModelCacheStatus()
        }
    }

    private var localQwenSegmentationSection: some View {
        Section("分段與後處理") {
            Toggle(
                "實驗性：本機切塊優先尋找靜音切點",
                isOn: setting(\.localSilenceAwareSegmentation)
            )
            Text("於 20 分鐘外層與 120 秒內層切點附近尋找至少 0.35 秒停頓，減少切斷字詞；僅套用至新加入工作。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Tab 3: 輸出 (Output)

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
                        HStack(spacing: AppSpacing.sm) {
                            Text(viewModel.settings.defaultOutputDirectory)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 300, alignment: .trailing)

                            Button("選擇…") {
                                viewModel.chooseDefaultOutputDirectory()
                            }

                            Button("在 Finder 顯示") {
                                viewModel.revealDefaultOutputDirectory()
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
                    text: $outputSuffixDraft,
                    prompt: Text(OutputNameBuilder.defaultFinalSuffix)
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit(commitOutputSuffixDraft)
                .onChange(of: outputSuffixDraft) { _, newValue in
                    viewModel.setSetting(
                        \.outputFilenameSuffix,
                        to: OutputNameBuilder.sanitizedSuffix(
                            newValue,
                            fallback: OutputNameBuilder.defaultFinalSuffix
                        )
                    )
                }

                filenamePreviewCard
            }

            Section("檔案編碼") {
                LabeledContent("格式") {
                    Text("UTF-8 · LF · 無 BOM")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var filenamePreviewCard: some View {
        let previewOutput = OutputNameBuilder.previewFileName(
            suffix: viewModel.settings.resolvedOutputFilenameSuffix
        )
        return HStack(spacing: AppSpacing.md) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
                Text("錄音.m4a")
                    .font(AppTypography.monoDetail)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AppColors.insetSurface, in: RoundedRectangle(cornerRadius: AppRadius.badge))

            Image(systemName: "arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(AppColors.accent)
                Text(previewOutput)
                    .font(AppTypography.monoDetail.weight(.medium))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AppColors.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: AppRadius.badge))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.badge)
                    .stroke(AppColors.accent.opacity(0.30), lineWidth: 1)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("檔名預覽：由 錄音.m4a 轉為 \(previewOutput)")
    }

    // MARK: - Tab 4: 資料與關於 (Data & About)

    private var dataAndAboutSettings: some View {
        Form {
            Section("最近工作") {
                Stepper(
                    "保留 \(viewModel.settings.recentJobLimit) 筆已完成紀錄",
                    value: setting(\.recentJobLimit),
                    in: 0...50
                )

                HStack(spacing: AppSpacing.sm) {
                    Button("清除已完成與失敗的記錄") {
                        viewModel.clearRecentJobs()
                    }
                    .disabled(!viewModel.hasFinishedJobs)

                    if viewModel.hasUnsuccessfulItemsToClean {
                        Button("清除未成功項目與殘留檔…", role: .destructive) {
                            isLocalUnsuccessfulCleanupPresented = true
                        }
                        .disabled(viewModel.isUnsuccessfulCleanupRunning)
                    }
                }

                Text("「清除已完成與失敗的記錄」僅移除列表項目，不會刪除原始錄音或文字檔。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("App 資料") {
                LabeledContent("Application Support") {
                    Text(viewModel.applicationSupportURL.path)
                        .font(AppTypography.monoDetail)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }

                HStack(spacing: AppSpacing.sm) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(viewModel.applicationSupportURL.path, forType: .string)
                        copiedAppSupportPath = true
                    } label: {
                        Label(
                            copiedAppSupportPath ? "已複製路徑" : "複製路徑",
                            systemImage: copiedAppSupportPath ? "checkmark" : "doc.on.doc"
                        )
                    }

                    Button("在 Finder 顯示") {
                        viewModel.revealApplicationSupport()
                    }
                }
            }

            Section("關於此 App") {
                LabeledContent("版本") {
                    Text("\(appVersionLabel) (\(appBuildNumber))")
                        .monospacedDigit()
                        .textSelection(.enabled)
                }

                LabeledContent("執行路徑") {
                    HStack(spacing: AppSpacing.sm) {
                        Text(Bundle.main.bundlePath)
                            .font(AppTypography.monoDetail)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Bundle.main.bundlePath, forType: .string)
                            copiedBundlePath = true
                        } label: {
                            Image(systemName: copiedBundlePath ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("複製執行路徑")
                    }
                }

                LabeledContent("長音預切策略") {
                    Text(segmentPolicyLabel)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("本機單段輸出上限") {
                    Text("\(defaultMaximumTokens.formatted()) tokens")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Section("重設") {
                HStack(spacing: AppSpacing.sm) {
                    Button("重設設定，保留詞庫…") {
                        resetChoice = .keepGlossaries
                    }
                    Button("重設設定與詞庫…", role: .destructive) {
                        resetChoice = .everything
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers & Actions

    private var appVersionLabel: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var appBuildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private var segmentPolicyLabel: String {
        let seconds = Int(AudioSegmentPlanner.productionMaximumDuration)
        let minutes = seconds / 60
        return "每段最長 \(minutes) 分鐘（\(seconds) 秒）"
    }

    private var defaultMaximumTokens: Int {
        16_384
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

    private func syncAllDraftsFromSettings() {
        apiKeyDraft = viewModel.settings.googleAIStudioAPIKey ?? ""
        vertexProjectDraft = viewModel.settings.vertexAIProjectID ?? ""
        vertexLocationDraft = viewModel.settings.vertexAILocation
        vertexBucketDraft = viewModel.settings.vertexAIGCSBucket ?? ""
        customGCloudPathDraft = viewModel.settings.customGCloudPath ?? ""
        customPythonPathDraft = viewModel.settings.customPythonPath ?? ""
        customHelperPathDraft = viewModel.settings.customHelperPath ?? ""
        outputSuffixDraft = viewModel.settings.outputFilenameSuffix ?? OutputNameBuilder.defaultFinalSuffix
    }

    private func commitPendingDrafts() {
        commitVertexLocationDraft()
        commitVertexBucketDraft()
        commitOutputSuffixDraft()
    }

    private func commitVertexLocationDraft() {
        let trimmed = vertexLocationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "global" : trimmed
        vertexLocationDraft = resolved
        viewModel.setSetting(\.vertexAILocation, to: resolved)
    }

    private func commitVertexBucketDraft() {
        let clean = normalizedBucketString(vertexBucketDraft)
        vertexBucketDraft = clean
        viewModel.setSetting(\.vertexAIGCSBucket, to: clean.isEmpty ? nil : clean)
    }

    private func commitOutputSuffixDraft() {
        let sanitized = OutputNameBuilder.sanitizedSuffix(
            outputSuffixDraft,
            fallback: OutputNameBuilder.defaultFinalSuffix
        )
        outputSuffixDraft = sanitized
        viewModel.setSetting(\.outputFilenameSuffix, to: sanitized)
    }

    private func normalizedBucketString(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("gs://") {
            trimmed.removeFirst(5)
            while trimmed.hasSuffix("/") {
                trimmed.removeLast()
            }
        }
        return trimmed
    }

    private func scheduleDebouncedEnvironmentRefresh() {
        environmentDebounceTask?.cancel()
        environmentDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            viewModel.refreshEnvironment()
        }
    }

    private func refreshDeveloperRuntimeDiscovery() {
        Task { @MainActor in
            let discovered = await Task.detached(priority: .utility) {
                RuntimeEnvironment.discoverDeveloperRuntime(fileManager: FileManager())
            }.value
            developerRuntimeDiscovery = discovered
        }
    }

    private func useAutoDetectedDeveloperRuntime() {
        customPythonPathDraft = ""
        customHelperPathDraft = ""
        viewModel.setSetting(\.customPythonPath, to: nil)
        viewModel.setSetting(\.customHelperPath, to: nil)
        viewModel.setSetting(\.developerMode, to: true)
        refreshDeveloperRuntimeDiscovery()
        viewModel.refreshEnvironment()
    }

    private func setting<Value>(
        _ keyPath: WritableKeyPath<AppSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { viewModel.settings[keyPath: keyPath] },
            set: { viewModel.setSetting(keyPath, to: $0) }
        )
    }

    private func testGoogleAIStudioAPIKey() {
        guard let key = normalizedAPIKeyDraft else {
            apiKeyTestResult = "請先輸入 API Key"
            apiKeyTestSucceeded = false
            return
        }

        let selectedModelID = viewModel.settings.googleAIStudioModelID

        apiKeyTestTask?.cancel()
        isTestingAPIKey = true
        apiKeyTestResult = nil
        apiKeyTestSucceeded = nil

        let needsSaveWarning = GoogleAIStudioAPIKeyDraftPolicy.shouldDisableSave(
            normalizedDraft: key,
            normalizedInMemoryAPIKey: normalizedInMemoryAPIKey,
            storageState: viewModel.googleAIStudioCredentialStorageState,
            hasPendingMigration: viewModel.hasPendingGoogleAIStudioCredentialMigration
        ) == false

        apiKeyTestTask = Task {
            let probeSession = GeminiTransportHelper.makeInteractiveProbeSession()
            defer { probeSession.finishTasksAndInvalidate() }
            let backend = GoogleAIStudioBackend(urlSession: probeSession)
            do {
                let probe = try await backend.validateConnectionAndModel(
                    apiKey: key,
                    modelID: selectedModelID
                )
                guard !Task.isCancelled else { return }
                let modelSummary = probe.displayName.map { "\($0)（\(probe.modelID)）" } ?? probe.modelID
                await MainActor.run {
                    isTestingAPIKey = false
                    apiKeyTestSucceeded = true
                    apiKeyTestResult = needsSaveWarning
                        ? "連線成功：API Key 與模型 \(modelSummary) 可用（請記得按「儲存到 Keychain」以套用至工作）。"
                        : "連線成功：API Key 與模型 \(modelSummary) 可用。"
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isTestingAPIKey = false
                    apiKeyTestSucceeded = false
                    apiKeyTestResult = "驗證失敗：\(error.localizedDescription)"
                }
            }
        }
    }

    private func testVertexAIAuthentication() {
        commitVertexLocationDraft()
        commitVertexBucketDraft()

        let explicitProject = vertexProjectDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let customGCloud = customGCloudPathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedLocation = viewModel.settings.vertexAILocation
        let selectedModelID = viewModel.settings.vertexAIModelID

        vertexAuthTestTask?.cancel()
        isTestingVertexAuth = true
        vertexAuthTestResult = nil
        vertexAuthTestSucceeded = nil

        vertexAuthTestTask = Task {
            let probeSession = GeminiTransportHelper.makeInteractiveProbeSession()
            defer { probeSession.finishTasksAndInvalidate() }
            let auth = GCloudAuthService(
                customGCloudPath: customGCloud.isEmpty ? nil : customGCloud
            )
            let backend = VertexAIGeminiBackend(
                authService: auth,
                urlSession: probeSession
            )
            do {
                let resolvedProject = try await backend.validateConnectionAndModel(
                    projectID: explicitProject.isEmpty ? nil : explicitProject,
                    location: selectedLocation,
                    modelID: selectedModelID
                )
                guard !Task.isCancelled else { return }
                let trimmedLocation = selectedLocation.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedLocation = trimmedLocation.isEmpty ? "global" : trimmedLocation
                await MainActor.run {
                    isTestingVertexAuth = false
                    vertexAuthTestSucceeded = true
                    vertexAuthTestResult = "驗證成功：專案 \(resolvedProject)（\(resolvedLocation)）與模型 \(selectedModelID) 連線可用。"
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isTestingVertexAuth = false
                    vertexAuthTestSucceeded = false
                    vertexAuthTestResult = "驗證失敗：\(error.localizedDescription)"
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
            return "一般、轉錄引擎與輸出設定會回到預設值，詞庫會保留。"
        case .everything:
            return "設定與所有詞庫都會清除。既有錄音與文字檔不受影響。"
        }
    }
}

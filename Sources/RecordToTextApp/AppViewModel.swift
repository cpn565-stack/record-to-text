import AppKit
import Foundation
import RecordToTextCore
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct UserFacingAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum ModelDownloadPhase: Equatable {
    case idle
    case importingLocal
    case downloading
    case succeeded(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .importingLocal, .downloading:
            return true
        case .idle, .succeeded, .failed:
            return false
        }
    }
}

enum GoogleAIStudioCredentialStorageState: Equatable {
    case absent
    case stored
    case memoryOnly
    case unavailable
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var settings: AppSettings
    @Published private(set) var glossaryCollection: GlossaryCollection
    @Published private(set) var jobs: [TranscriptionJob]
    @Published private(set) var recentJobs: [RecentJobSummary]
    @Published private(set) var activeJobID: UUID?
    @Published private(set) var environmentReport: EnvironmentReport?
    @Published private(set) var isSelectedModelCached = false
    @Published private(set) var isSelectedModelInDefaultHFCache = false
    @Published private(set) var modelDownloadPhase: ModelDownloadPhase = .idle
    @Published private(set) var modelDownloadProgressLine: String = ""
    @Published private(set) var recoveryScanReport: RecoveryScanReport?
    @Published private(set) var isRecoveryScanRunning = false
    @Published private(set) var isModelCacheStatusRefreshing = false
    @Published private(set) var isGoogleAIStudioCredentialLoading = true
    private var credentialLoadingTask: Task<Void, Never>?
    @Published private(set) var isGoogleAIStudioCredentialSaving = false
    @Published private(set) var googleAIStudioCredentialStorageState:
        GoogleAIStudioCredentialStorageState = .absent

    @Published var alert: UserFacingAlert?
    @Published var isPromptPreviewPresented = false
    @Published var isGlossaryManagerPresented = false
    @Published var isEnvironmentPresented = false
    @Published var isOnboardingPresented: Bool
    @Published var isDuplicateConfirmationPresented = false
    @Published var isPromptConsentPresented = false
    @Published var isRecoveryScanPresented = false
    /// Pending delete confirmation for recovery scan UI.
    @Published var recoveryItemPendingDeletion: RecoveryScanItem?
    @Published var isBulkCleanupConfirmationPresented = false

    @Published private(set) var jobPersistenceError: String?
    private var persistenceRevision: UInt64 = 0
    private var jobPersistenceLoadBlocked = false
    private var jobPersistenceDeferred = false
    private var persistenceSubmission: Task<Void, Never>?
    private var pendingPersistenceSubmission: (PersistenceSnapshot, JobPersistenceCoordinator.Urgency)?
    private lazy var jobPersistence = JobPersistenceCoordinator(
        initialRevision: persistenceRevision,
        writer: { [paths, jobLedgerSaveOverride] snapshot in
            try jobLedgerSaveOverride?(JobLedgerCollection(jobs: snapshot.canonical().jobs))
            try JobPersistenceStore(ledgerURL: paths.jobLedger, recentURL: paths.recentJobs).write(snapshot)
            OutputPublicationStore(paths: paths).prune(after: snapshot)
        },
        observer: { [weak self] status in
            Task { @MainActor in self?.jobPersistenceError = status.error }
        }
    )
    private let paths: ApplicationPaths
    private let engineFactory: ((ResolvedRuntime) -> TranscriptionEngine)?
    private let settingsRepository: JSONRepository<AppSettings>
    private let glossaryRepository: JSONRepository<GlossaryCollection>
    private let recentJobsRepository: JSONRepository<RecentJobCollection>
    private let jobLedgerRepository: JSONRepository<JobLedgerCollection>
    private let credentialStore: any GoogleAIStudioCredentialStoring
    private let saveSettingsValue: (AppSettings) throws -> Void
    private let jobLedgerSaveOverride: ((JobLedgerCollection) throws -> Void)?
    private let fileManager: FileManager
    private let modelDownloadRunner = ProcessRunner()

    private var queueTask: Task<Void, Never>?
    private var activeExecutionTask: Task<PipelineResult, Error>?
    private var activeEngine: TranscriptionEngine?
    private var reusableEngine: TranscriptionEngine?
    private var reusableEngineRuntime: ResolvedRuntime?
    private var modelDownloadTask: Task<Void, Never>?
    private var modelCacheStatusTask: Task<Void, Never>?
    private var recoveryScanTask: Task<Void, Never>?
    private var modelCacheRefreshGeneration = 0
    private var recoveryScanGeneration = 0
    @Published private(set) var manualDrainRequested = false
    private var pendingDuplicateURLs: [URL] = []
    private var promptConsentJobID: UUID?
    private var cancellationRequested = Set<UUID>()
    private var allowMissingPrompt = Set<UUID>()
    private var queuePausedForPromptConsent = false
    private var resumeQueueAfterPromptConsent = false
    private var queuePausedForEnvironment = false
    private var networkContinuationInFlight = Set<UUID>()
    private var terminatingForNetwork = Set<UUID>()
    private var isTerminating = false
    var queuePausedForNetwork: Bool {
        !networkContinuationInFlight.isEmpty || jobs.contains {
            $0.stage == .interrupted && $0.networkRecovery != nil && $0.networkRecovery?.state != .resolved
        }
    }
    private var legacySettingsCredentialMigrationPending = false
    private var legacyLedgerCredentialMigrationPending = false
    private var credentialStoreSynchronizedForLegacyMigration = false

    init(
        paths: ApplicationPaths = .live(),
        fileManager: FileManager = .default,
        credentialStore: any GoogleAIStudioCredentialStoring = KeychainGoogleAIStudioCredentialStore(),
        settingsSaveOverride: ((AppSettings) throws -> Void)? = nil,
        jobLedgerSaveOverride: ((JobLedgerCollection) throws -> Void)? = nil,
        engineFactory: ((ResolvedRuntime) -> TranscriptionEngine)? = nil
    ) {
        self.paths = paths
        self.engineFactory = engineFactory
        self.fileManager = fileManager
        self.credentialStore = credentialStore
        let settingsRepository = JSONRepository<AppSettings>(url: paths.settings)
        let jobLedgerRepository = JSONRepository<JobLedgerCollection>(url: paths.jobLedger)
        self.settingsRepository = settingsRepository
        self.glossaryRepository = JSONRepository(url: paths.glossaries)
        self.recentJobsRepository = JSONRepository(url: paths.recentJobs)
        self.jobLedgerRepository = jobLedgerRepository
        self.saveSettingsValue = settingsSaveOverride ?? { value in
            try settingsRepository.save(value)
        }
        self.jobLedgerSaveOverride = jobLedgerSaveOverride

        var startupMessages: [String] = []
        do {
            try paths.createDirectories(fileManager: fileManager)
        } catch {
            startupMessages.append("無法建立 App 資料夾：\(error.localizedDescription)")
        }

        var loadedSettings: AppSettings
        do {
            loadedSettings = try settingsRepository.load(
                default: AppSettings.defaultValue(fileManager: fileManager)
            )
        } catch {
            loadedSettings = AppSettings.defaultValue(fileManager: fileManager)
            startupMessages.append("設定檔無法讀取，已改用預設值：\(error.localizedDescription)")
        }

        let loadedGlossaries: GlossaryCollection
        do {
            loadedGlossaries = try glossaryRepository.load(default: GlossaryCollection())
        } catch {
            loadedGlossaries = GlossaryCollection()
            startupMessages.append("詞庫無法讀取：\(error.localizedDescription)")
        }

        let recoveredJournal: PersistenceSnapshot?
        do {
            recoveredJournal = try JobPersistenceStore(ledgerURL: paths.jobLedger, recentURL: paths.recentJobs).recover(repairOutputs: false)
            persistenceRevision = recoveredJournal?.revision ?? 0
        } catch {
            recoveredJournal = nil
            jobPersistenceLoadBlocked = true
            let message = "工作 journal 無法復原；已保留原始紀錄，停止覆寫：\(error.localizedDescription)"
            jobPersistenceError = message
            startupMessages.append(message)
        }
        let recentJobsOutcome = LenientCollectionLoader.loadRecentJobs(
            at: paths.recentJobs,
            fileManager: fileManager
        )
        let loadedRecentJobs = recoveredJournal.map { RecentJobCollection(jobs: $0.recentJobs) } ?? recentJobsOutcome.value
        if let message = recentJobsOutcome.diagnosticMessage {
            startupMessages.append(message)
        }

        let ledgerOutcome = LenientCollectionLoader.loadJobLedger(
            at: paths.jobLedger,
            fileManager: fileManager
        )
        var loadedLedger = recoveredJournal.map { JobLedgerCollection(jobs: $0.jobs) } ?? ledgerOutcome.value
        if let message = ledgerOutcome.diagnosticMessage {
            startupMessages.append(message)
        }

        let legacySettingsAPIKey = Self.normalizedAPIKey(
            loadedSettings.googleAIStudioAPIKey
        )
        let legacyLedgerAPIKey = loadedLedger.jobs.lazy.compactMap {
            Self.normalizedAPIKey($0.snapshot.googleAIStudioAPIKey)
        }.first
        let hasLegacySettingsCredential = legacySettingsAPIKey != nil
        let hasLegacyLedgerCredential = legacyLedgerAPIKey != nil
        loadedSettings.googleAIStudioAPIKey = legacySettingsAPIKey ?? legacyLedgerAPIKey

        do {
            loadedLedger.jobs = try OutputPublicationStore(paths: paths).recoverKnownJobs(loadedLedger.jobs)
        } catch {
            startupMessages.append("輸出發布紀錄核對失敗，已保留原檔：\(error.localizedDescription)")
        }
        var summaries = loadedRecentJobs.jobs
        var didInterruptJobs = false
        for index in loadedLedger.jobs.indices where loadedLedger.jobs[index].stage == .interrupted {
            let job = loadedLedger.jobs[index]
            let continuationNotStarted = job.networkRecovery?.state == .resolved && job.networkContinuationJobID.map { id in
                loadedLedger.jobs.contains { $0.id == id && $0.stage == .queued }
            } == true
            if job.networkRecovery?.state == .unknown || continuationNotStarted {
                loadedLedger.jobs[index].networkRecovery?.state = .paused
                loadedLedger.jobs[index].networkRecovery?.stopReason = .appRestarted
                didInterruptJobs = true
            }
        }
        for index in loadedLedger.jobs.indices where !loadedLedger.jobs[index].stage.isTerminal {
            // Queued work was never sent and must remain queued across a pause.
            if loadedLedger.jobs[index].stage == .queued { continue }
            let interruptedJob = loadedLedger.jobs[index]
            loadedLedger.jobs[index].stage = .interrupted
            loadedLedger.jobs[index].completedAt = Date()
            loadedLedger.jobs[index].logLines.append("App 上次結束時工作尚未完成。")
            if interruptedJob.snapshot.backendType != .localQwen {
                var recovery = interruptedJob.networkRecovery ?? .init(state: .paused,
                    waitedSeconds: 0, remainingWaitSeconds: 300, segmentIndex: 1, segmentCount: 1,
                    completedSegmentCount: 0, resultUnknown: true)
                recovery.state = .paused; recovery.stopReason = .appRestarted
                loadedLedger.jobs[index].networkRecovery = recovery
                let directory = paths.tempRecovery.appendingPathComponent(interruptedJob.id.uuidString)
                loadedLedger.jobs[index].failure = JobFailure(stage: .interrupted,
                    userMessage: "上次雲端工作尚未完成，已保留工作；請手動重新嘗試或續跑。",
                    technicalDetails: "Cloud job interrupted by app restart.", recoverable: true,
                    recoveryDirectory: fileManager.fileExists(atPath: directory.path) ? directory.path : nil)
            }
            if interruptedJob.snapshot.backendType == .localQwen {
                let directory = paths.tempRecovery.appendingPathComponent(
                    interruptedJob.id.uuidString,
                    isDirectory: true
                )
                if LocalChunkCheckpoint.containsUsableCheckpoint(
                    in: directory,
                    fileManager: fileManager
                ) {
                    loadedLedger.jobs[index].failure = JobFailure(
                        stage: .interrupted,
                        userMessage: "App 上次結束時 Qwen 工作尚未完成；已找到可驗證的 chunk checkpoint。",
                        technicalDetails: "Recovered local Qwen chunk checkpoint after interrupted app session.",
                        recoverable: true,
                        recoveryDirectory: directory.path,
                        partialTranscriptPath: nil
                    )
                    loadedLedger.jobs[index].logLines.append(
                        "已找到本機 Qwen chunk checkpoint，可從已完成 chunk 續跑。"
                    )
                }
            }
            let summary = RecentJobSummary(job: loadedLedger.jobs[index])
            summaries.removeAll(where: { $0.id == summary.id })
            summaries.append(summary)
            didInterruptJobs = true
        }

        self.settings = loadedSettings
        self.glossaryCollection = loadedGlossaries
        self.jobs = loadedLedger.jobs
        self.recentJobs = summaries
        self.isOnboardingPresented = !loadedSettings.hasCompletedOnboarding
        self.legacySettingsCredentialMigrationPending = hasLegacySettingsCredential
        self.legacyLedgerCredentialMigrationPending = hasLegacyLedgerCredential
        self.googleAIStudioCredentialStorageState =
            loadedSettings.googleAIStudioAPIKey == nil ? .absent : .memoryOnly

        if !startupMessages.isEmpty {
            self.alert = UserFacingAlert(
                title: "部分資料未能載入",
                message: startupMessages.joined(separator: "\n\n")
            )
        }

        if didInterruptJobs {
            persistJobs()
        }
        beginCredentialLoading(legacyAPIKey: legacySettingsAPIKey ?? legacyLedgerAPIKey)

        // Model-cache and recovery scans touch many directories; defer them
        // past the first frame so launch stays responsive. Both only publish
        // results when ready.
        Task { [weak self] in
            self?.refreshSelectedModelCacheStatus()
            // Read-only inventory only — never deletes on startup.
            self?.runRecoveryScan(presentIfNonEmpty: true)
        }
    }

    /// A dedicated queue keeps blocking Keychain calls off both the main actor
    /// and Swift's cooperative executor. Only one startup read may be in flight.
    private func beginCredentialLoading(legacyAPIKey: String?) {
        let store = credentialStore
        credentialLoadingTask = Task { [weak self] in
            let outcome: Result<String?, Error> = await withCheckedContinuation { continuation in
                DispatchQueue(label: "record-to-text.credential-startup", qos: .userInitiated).async {
                    let result = Result<String?, Error> {
                        let stored = try store.loadAPIKey()
                        let resolved = stored ?? legacyAPIKey
                        if stored == nil, resolved != nil {
                            try store.saveAPIKey(resolved)
                        }
                        return resolved
                    }
                    continuation.resume(returning: result)
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.isGoogleAIStudioCredentialLoading = false
            switch outcome {
            case let .success(key):
                // Merge into current settings so edits made during loading survive.
                self.settings.googleAIStudioAPIKey = key
                self.googleAIStudioCredentialStorageState = key == nil ? .absent : .stored
                self.credentialStoreSynchronizedForLegacyMigration =
                    self.hasPendingGoogleAIStudioCredentialMigration
                self.persistSettings()
                self.persistJobs()
            case let .failure(error):
                self.persistJobs()
                self.googleAIStudioCredentialStorageState =
                    self.settings.googleAIStudioAPIKey == nil ? .unavailable : .memoryOnly
                let message = "Google AI Studio API Key 無法從 Keychain 載入：\(error.localizedDescription)。可在設定中重試；其他功能仍可使用。"
                self.alert = UserFacingAlert(
                    title: "部分資料未能載入",
                    message: [self.alert?.message, message].compactMap { $0 }.joined(separator: "\n\n")
                )
            }
            self.scheduleQueueIfNeeded()
        }
    }

    func waitForCredentialLoading() async {
        await credentialLoadingTask?.value
        try? await flushJobPersistence()
    }

    deinit {
        credentialLoadingTask?.cancel()
        queueTask?.cancel()
        activeExecutionTask?.cancel()
        activeEngine?.cancelCurrentJob()
        reusableEngine?.cancelCurrentJob()
        modelDownloadTask?.cancel()
        modelCacheStatusTask?.cancel()
        recoveryScanTask?.cancel()
        modelDownloadRunner.cancelCurrent()
        settingsPersistTask?.cancel()
    }

    // MARK: - Read-only presentation state

    var selectedGlossary: GlossaryPreset? {
        guard let selectedID = settings.lastSelectedGlossaryID else {
            return nil
        }
        return glossaryCollection.glossaries.first(where: { $0.id == selectedID })
    }

    var selectedModelName: String {
        switch settings.backendType {
        case .googleAIStudio:
            if let preset = GeminiModelDescriptor.presetModels.first(where: { $0.id == settings.googleAIStudioModelID }) {
                return "Google AI Studio (\(preset.displayName))"
            }
            return "Google AI Studio (\(settings.googleAIStudioModelID))"
        case .vertexAI:
            if let preset = GeminiModelDescriptor.presetModels.first(where: { $0.id == settings.vertexAIModelID }) {
                return "Vertex AI (\(preset.displayName))"
            }
            return "Vertex AI (\(settings.vertexAIModelID))"
        case .localQwen:
            return ASRModelDescriptor.descriptor(id: settings.selectedModelID)?.displayName
                ?? settings.selectedModelID
        }
    }

    var selectedModelIcon: String {
        settings.backendType == .localQwen
            ? (CPUArchitecture.current == .x86_64 ? "cpu" : "apple.logo")
            : "cloud.fill"
    }

    var selectedQuickTranscriptionChoice: QuickTranscriptionChoice? {
        QuickTranscriptionChoice.allCases.first { $0.matches(settings) }
    }

    var appSubtitle: String {
        switch settings.backendType {
        case .googleAIStudio:
            return "透過 Google AI Studio (Gemini) 產出台灣繁體逐字稿。"
        case .vertexAI:
            return "透過 Google Cloud Vertex AI (Gemini)，直接產出台灣繁體逐字稿。"
        case .localQwen:
            return "把會議錄音留在這台 Mac，產生可繼續整理的台灣繁體文字稿。"
        }
    }

    var selectedModelDetail: String? {
        switch settings.backendType {
        case .googleAIStudio:
            return GeminiModelDescriptor.presetModels.first(where: { $0.id == settings.googleAIStudioModelID })?.note
        case .vertexAI:
            return GeminiModelDescriptor.presetModels.first(where: { $0.id == settings.vertexAIModelID })?.note
        case .localQwen:
            return ASRModelDescriptor.descriptor(id: settings.selectedModelID)?.detail
        }
    }

    var availableModels: [ASRModelDescriptor] {
        ASRModelDescriptor.currentAvailable
    }

    var modelDownloadButtonTitle: String {
        if modelDownloadPhase.isBusy {
            return modelDownloadPhase == .importingLocal ? "匯入中…" : "下載中…"
        }
        if isSelectedModelCached {
            return "已下載"
        }
        if isSelectedModelInDefaultHFCache {
            return "匯入本機模型"
        }
        return "下載模型"
    }

    var canDownloadSelectedModel: Bool {
        !modelDownloadPhase.isBusy && !isSelectedModelCached
    }

    var promptPreview: String {
        (try? buildPrompt().prompt) ?? ""
    }

    var promptTermCount: Int {
        (try? buildPrompt().terms.count) ?? 0
    }

    var promptErrorMessage: String? {
        do {
            _ = try buildPrompt()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var hasQueuedJobs: Bool {
        jobs.contains(where: { $0.stage == .queued })
    }

    var splittableQueuedJobs: [TranscriptionJob] {
        jobs.filter { $0.stage == .queued && $0.sourceSlice == nil }
    }

    var hasSplittableQueuedJobs: Bool {
        !splittableQueuedJobs.isEmpty
    }

    var hasActiveJob: Bool {
        activeJobID != nil
    }

    var activeJob: TranscriptionJob? {
        guard let activeJobID else {
            return nil
        }
        return jobs.first(where: { $0.id == activeJobID })
    }

    var outputLocationSummary: String {
        switch settings.outputLocationMode {
        case .fixedDirectory:
            return settings.defaultOutputDirectory
        case .sameAsSource:
            return "與來源音檔相同"
        case .askEveryTime:
            return "加入檔案時選擇"
        }
    }

    var runtimeModeDescription: String {
        settings.developerMode ? "Developer Mode" : "App 管理的 Runtime"
    }

    var applicationSupportURL: URL {
        paths.root
    }

    // MARK: - Settings

    /// Typing in a settings field used to hit the disk synchronously on every
    /// keystroke; changes now coalesce into one write shortly after typing
    /// stops. Explicit `persistSettings()` calls (credentials, migrations)
    /// remain immediate.
    private var settingsPersistTask: Task<Void, Never>?
    private static let settingsPersistInterval: Duration = .milliseconds(600)

    func setSetting<Value>(
        _ keyPath: WritableKeyPath<AppSettings, Value>,
        to value: Value
    ) {
        var updated = settings
        updated[keyPath: keyPath] = value
        if (keyPath as AnyKeyPath) == (\AppSettings.googleAIStudioAPIKey as AnyKeyPath) {
            Task { await setGoogleAIStudioAPIKey(updated.googleAIStudioAPIKey) }
            return
        }
        settings = updated
        let engineKeys: [AnyKeyPath] = [\AppSettings.backendType, \AppSettings.selectedModels,
            \AppSettings.googleAIStudioModelID, \AppSettings.vertexAIModelID,
            \AppSettings.vertexAIProjectID, \AppSettings.vertexAILocation,
            \AppSettings.vertexAIGCSBucket, \AppSettings.vertexAIIncludeSummary,
            \AppSettings.geminiThinkingLevel, \AppSettings.cloudFallbackPolicy,
            \AppSettings.silenceAwareCloudSegmentation]
        if engineKeys.contains(keyPath) { synchronizeQueuedEngineSettings() }
        scheduleSettingsPersist()
    }

    /// Fresh queued jobs follow the visible selection; running and checkpoint jobs
    /// keep their execution contract so we never switch an in-flight upload.
    private func synchronizeQueuedEngineSettings() {
        var changed = false
        for index in jobs.indices where jobs[index].canUpdateQueuedEngine(activeJobID: activeJobID) {
            let previous = jobs[index].snapshot
            let next = previous.withEngineSettings(settings)
            if previous != next {
                jobs[index].snapshot = next
                changed = true
            }
        }
        if changed { persistJobs() }
    }

    func scheduleSettingsPersist() {
        settingsPersistTask?.cancel()
        settingsPersistTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settingsPersistInterval)
            guard let self, !Task.isCancelled else {
                return
            }
            self.persistSettings()
            self.settingsPersistTask = nil
        }
    }

    /// Flushes a debounced settings write before the App terminates. The
    /// termination path is synchronous when no transcription is active, so a
    /// pending Task cannot be allowed to disappear with the view model.
    func flushPendingSettingsPersistence() {
        guard settingsPersistTask != nil else {
            return
        }
        settingsPersistTask?.cancel()
        settingsPersistTask = nil
        persistSettings()
    }

    var googleAIStudioCredentialStorageDescription: String {
        if isGoogleAIStudioCredentialLoading {
            return "正在載入 Google AI Studio 設定；其他功能可繼續使用，AI Studio 工作會在載入後開始。"
        }
        switch googleAIStudioCredentialStorageState {
        case .absent:
            return "尚未儲存憑證。貼上後請按「儲存到 Keychain」。"
        case .stored:
            if hasPendingGoogleAIStudioCredentialMigration {
                return "API Key 已儲存於 macOS Keychain，但舊版設定或工作記錄尚未完成去密；請使用同一內容再按一次「儲存到 Keychain」。"
            }
            return "目前憑證已儲存於 macOS Keychain。編輯內容不會在每次鍵入時覆蓋舊憑證。"
        case .memoryOnly:
            return "目前憑證只在這次 App 開啟期間可用，尚未儲存到 Keychain；可按儲存重試。"
        case .unavailable:
            return "Keychain 狀態無法確認或更新；可再按儲存或清除重試。"
        }
    }

    var hasPendingGoogleAIStudioCredentialMigration: Bool {
        legacySettingsCredentialMigrationPending
            || legacyLedgerCredentialMigrationPending
    }

    /// Stores the credential in macOS Keychain and only keeps an in-memory
    /// copy for UI display and transient request execution.
    @discardableResult
    func setGoogleAIStudioAPIKey(_ apiKey: String?) async -> Bool {
        guard !isGoogleAIStudioCredentialLoading, !isGoogleAIStudioCredentialSaving else { return false }
        isGoogleAIStudioCredentialSaving = true
        defer { isGoogleAIStudioCredentialSaving = false }
        let normalized = Self.normalizedAPIKey(apiKey)
        if normalized == nil {
            return await clearGoogleAIStudioAPIKey()
        }

        do {
            try credentialStore.saveAPIKey(normalized)
            var updated = settings
            updated.googleAIStudioAPIKey = normalized
            settings = updated
            googleAIStudioCredentialStorageState = .stored
            if legacySettingsCredentialMigrationPending
                || legacyLedgerCredentialMigrationPending
            {
                credentialStoreSynchronizedForLegacyMigration = true
            }
            // A successful Keychain write authorizes redacting pending legacy
            // JSON copies. Report any persistence failure to the caller even
            // though the credential itself is already safely stored.
            let settingsSaved = persistSettings()
            let ledgerSaved = await finishLegacyLedgerMigration()
            return settingsSaved && ledgerSaved
        } catch {
            credentialStoreSynchronizedForLegacyMigration = false
            var updated = settings
            updated.googleAIStudioAPIKey = normalized
            settings = updated
            googleAIStudioCredentialStorageState = .memoryOnly
            alert = UserFacingAlert(
                title: "無法儲存 API Key",
                message: "API Key 只會保留到這次開啟 App 結束，可用同一內容重試：\(error.localizedDescription)"
            )
            return false
        }
    }

    /// Clears a credential as a small transaction. Any legacy JSON copies are
    /// first backed by a confirmed Keychain value and then redacted. The
    /// Keychain item is deleted only after every pending redaction succeeds.
    private func clearGoogleAIStudioAPIKey() async -> Bool {
        let previousSettings = settings
        let previousAPIKey = Self.normalizedAPIKey(
            previousSettings.googleAIStudioAPIKey
        )
        let hasPendingLegacyCredential = legacySettingsCredentialMigrationPending
            || legacyLedgerCredentialMigrationPending

        if hasPendingLegacyCredential,
           !ensureLegacyCredentialStoreIsSynchronized(
               credential: previousAPIKey
           )
        {
            alert = UserFacingAlert(
                title: "無法清除 API Key",
                message: "舊版憑證還沒有安全寫入 Keychain，因此 App 沒有改寫舊版 JSON，也沒有刪除憑證。請稍後再試。"
            )
            return false
        }

        var clearedSettings = settings
        clearedSettings.googleAIStudioAPIKey = nil
        settings = clearedSettings

        // Make progress on both files even if one fails. The Keychain value
        // remains untouched unless both pending legacy copies were redacted.
        let settingsSanitized = !legacySettingsCredentialMigrationPending
            || persistSettings()
        let ledgerSanitized = await finishLegacyLedgerMigration()
        guard settingsSanitized, ledgerSanitized else {
            settings = previousSettings
            googleAIStudioCredentialStorageState = previousAPIKey == nil
                ? .unavailable
                : .stored
            alert = UserFacingAlert(
                title: "無法清除 API Key",
                message: "舊版設定或工作記錄還沒有全部去除憑證，因此 Keychain 內的 API Key 已保留，避免下次開啟時出現不一致。請排除儲存問題後再試。"
            )
            return false
        }

        do {
            try credentialStore.saveAPIKey(nil)
            googleAIStudioCredentialStorageState = .absent
            credentialStoreSynchronizedForLegacyMigration = false
            return true
        } catch {
            let restorationSucceeded: Bool
            if let previousAPIKey {
                do {
                    try credentialStore.saveAPIKey(previousAPIKey)
                    restorationSucceeded = true
                } catch {
                    restorationSucceeded = false
                }
            } else {
                restorationSucceeded = false
            }

            settings = previousSettings
            googleAIStudioCredentialStorageState = restorationSucceeded
                ? .stored
                : .unavailable
            alert = UserFacingAlert(
                title: "無法清除 API Key",
                message: restorationSucceeded
                    ? "Keychain 刪除回報失敗，App 已回存原本憑證，目前仍可使用。請再試一次：\(error.localizedDescription)"
                    : "Keychain 刪除失敗，也無法確認原憑證是否已回存。App 已保留這次開啟期間的憑證，請稍後再試：\(error.localizedDescription)"
            )
            return false
        }
    }

    func setTemporaryTerms(_ value: String) {
        setSetting(\.lastTemporaryTerms, to: value)
    }

    func selectGlossary(_ id: String?) {
        setSetting(\.lastSelectedGlossaryID, to: id)
    }

    func setNotificationPreference(_ enabled: Bool) {
        setSetting(\.showNotificationWhenCompleted, to: enabled)
        if enabled {
            requestNotificationAuthorization()
        }
    }

    func setSelectedModelID(_ modelID: String) {
        var selectedModels = settings.selectedModels
        selectedModels[CPUArchitecture.current.rawValue] = modelID
        setSetting(\.selectedModels, to: selectedModels)
        refreshSelectedModelCacheStatus()
        if case .succeeded = modelDownloadPhase {
            modelDownloadPhase = .idle
            modelDownloadProgressLine = ""
        }
        if case .failed = modelDownloadPhase {
            modelDownloadPhase = .idle
            modelDownloadProgressLine = ""
        }
    }

    func selectQuickTranscriptionChoice(_ choice: QuickTranscriptionChoice) {
        settings = choice.applying(to: settings)
        synchronizeQueuedEngineSettings()
        scheduleSettingsPersist()

        if choice.backendType == .localQwen {
            refreshSelectedModelCacheStatus()
        }
        if case .succeeded = modelDownloadPhase {
            modelDownloadPhase = .idle
            modelDownloadProgressLine = ""
        }
        if case .failed = modelDownloadPhase {
            modelDownloadPhase = .idle
            modelDownloadProgressLine = ""
        }
        refreshEnvironment()
    }

    func refreshSelectedModelCacheStatus() {
        let modelID = settings.selectedModelID
        let revision = selectedModelRevision
        let modelsDirectory = paths.models
        modelCacheStatusTask?.cancel()
        modelCacheRefreshGeneration += 1
        let generation = modelCacheRefreshGeneration
        isModelCacheStatusRefreshing = true
        modelCacheStatusTask = Task { [weak self] in
            let status = await Task.detached(priority: .utility) {
                StartupInventory.modelCache(
                    modelID: modelID,
                    revision: revision,
                    modelsDirectory: modelsDirectory,
                    fileManager: FileManager()
                )
            }.value
            guard let self,
                  !Task.isCancelled,
                  generation == self.modelCacheRefreshGeneration
            else {
                return
            }
            self.isSelectedModelCached =
                status.isAppManagedModelAvailable
            self.isSelectedModelInDefaultHFCache =
                status.isDefaultCacheModelAvailable
            self.isModelCacheStatusRefreshing = false
        }
    }

    func downloadSelectedModel() {
        guard canDownloadSelectedModel else {
            return
        }
        guard !modelDownloadRunner.isRunning else {
            alert = UserFacingAlert(
                title: "模型下載忙碌中",
                message: "已有模型下載程序在執行。"
            )
            return
        }

        let modelID = settings.selectedModelID
        let revision = selectedModelRevision
        modelDownloadTask?.cancel()
        modelDownloadTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.performModelDownload(modelID: modelID, revision: revision)
        }
    }

    func cancelModelDownload() {
        modelDownloadRunner.cancelCurrent()
        modelDownloadTask?.cancel()
        modelDownloadPhase = .idle
        modelDownloadProgressLine = "已取消下載。"
        refreshSelectedModelCacheStatus()
    }

    func chooseDefaultOutputDirectory() {
        guard let directory = chooseDirectory(
            title: "選擇預設輸出資料夾",
            initialPath: settings.defaultOutputDirectory
        ) else {
            return
        }

        var updated = settings
        updated.defaultOutputDirectory = directory.path
        updated.lastOutputDirectory = directory.path
        settings = updated
        persistSettings()
    }

    @discardableResult
    func resetSettings(keepGlossaries: Bool) async -> Bool {
        guard !isGoogleAIStudioCredentialLoading, !isGoogleAIStudioCredentialSaving else { return false }
        let shouldClearCredential = Self.normalizedAPIKey(
            settings.googleAIStudioAPIKey
        ) != nil
            || googleAIStudioCredentialStorageState != .absent
            || legacySettingsCredentialMigrationPending
            || legacyLedgerCredentialMigrationPending
        let credentialCleared = shouldClearCredential ? await setGoogleAIStudioAPIKey(nil) : true

        var resetSettings = AppSettings.defaultValue(fileManager: fileManager)
        if !credentialCleared {
            // The reset still applies non-secret preferences, but it must not
            // claim that a credential was cleared when the transaction failed.
            resetSettings.googleAIStudioAPIKey = settings.googleAIStudioAPIKey
        }
        settings = resetSettings
        if !keepGlossaries {
            glossaryCollection = GlossaryCollection()
            persistGlossaries()
        }
        let settingsSaved = persistSettings()
        refreshEnvironment()
        return credentialCleared && settingsSaved
    }

    func clearRecentJobs() {
        removeAllFinishedJobs()
    }

    /// Removes one finished job (failed / cancelled / interrupted / completed)
    /// from the live list and recent history. Does not delete source audio,
    /// output TXT, or Temp-Recovery folders.
    func removeFinishedJob(_ id: UUID) {
        guard !networkContinuationInFlight.contains(id) else { return }
        if let job = jobs.first(where: { $0.id == id }) {
            guard job.stage.isTerminal else {
                return
            }
            if job.networkRecovery != nil { manualDrainRequested = false }
            jobs.removeAll(where: { $0.id == id })
        }
        recentJobs.removeAll(where: { $0.id == id })
        persistJobs()
    }

    /// Clears every finished job from the queue and the recent-jobs list.
    /// Active and queued work are kept.
    func removeAllFinishedJobs() {
        if queuePausedForNetwork { manualDrainRequested = false }
        jobs.removeAll(where: { $0.stage.isTerminal && !networkContinuationInFlight.contains($0.id) })
        recentJobs.removeAll()
        persistJobs()
    }

    var hasFinishedJobs: Bool {
        jobs.contains(where: { $0.stage.isTerminal }) || !recentJobs.isEmpty
    }

    func revealApplicationSupport() {
        try? fileManager.createDirectory(
            at: paths.root,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([paths.root])
    }

    // MARK: - Glossaries

    @discardableResult
    func createGlossary(name: String = "新詞庫", terms: [String] = []) -> String {
        let glossary = GlossaryPreset(name: uniqueGlossaryName(name), terms: terms)
        glossaryCollection.glossaries.append(glossary)
        persistGlossaries()
        selectGlossary(glossary.id)
        return glossary.id
    }

    @discardableResult
    func updateGlossary(id: String, name: String, termsText: String) -> Bool {
        guard let index = glossaryCollection.glossaries.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            alert = UserFacingAlert(title: "詞庫名稱不能空白", message: "請輸入一個容易辨識的名稱。")
            return false
        }

        glossaryCollection.glossaries[index].name = trimmedName
        glossaryCollection.glossaries[index].terms = TermParser.parse(termsText)
        glossaryCollection.glossaries[index].updatedAt = Date()
        persistGlossaries()
        return true
    }

    func updateCommonTerms(_ termsText: String) {
        glossaryCollection.commonTerms = TermParser.parse(termsText)
        persistGlossaries()
    }

    func deleteGlossary(id: String) {
        glossaryCollection.glossaries.removeAll(where: { $0.id == id })
        if settings.lastSelectedGlossaryID == id {
            selectGlossary(nil)
        }
        persistGlossaries()
    }

    // MARK: - File intake

    func chooseAudioFiles() {
        let panel = NSOpenPanel()
        panel.title = "選擇會議錄音"
        panel.prompt = "加入佇列"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.allowedContentTypes = AudioProbeService.supportedExtensions
            .compactMap { UTType(filenameExtension: $0) }

        if let lastInputDirectory = settings.lastInputDirectory {
            panel.directoryURL = URL(fileURLWithPath: lastInputDirectory, isDirectory: true)
        }

        guard panel.runModal() == .OK else {
            return
        }

        if let first = panel.urls.first {
            setSetting(
                \.lastInputDirectory,
                to: first.deletingLastPathComponent().path as String?
            )
        }
        addFiles(panel.urls)
    }

    func splitQueuedAudioFileInHalf(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }),
              job.stage == .queued,
              job.sourceSlice == nil
        else {
            return
        }

        Task { @MainActor [weak self] in
            await self?.prepareAndSplitQueuedJob(id)
        }
    }

    private func prepareAndSplitQueuedJob(_ id: UUID) async {
        do {
            guard let job = jobs.first(where: { $0.id == id }),
                  job.stage == .queued,
                  job.sourceSlice == nil
            else {
                return
            }

            let runtime = runtimeCandidate()
            let metadata = try await AudioProbeService(
                executableURL: runtime.ffprobe
            ).probe(job.sourceURL)
            guard metadata.duration >= 2 else {
                alert = UserFacingAlert(
                    title: "音檔太短，無法切半",
                    message: "音檔長度需要至少 2 秒。"
                )
                return
            }

            let slices = TranscriptionSourceSlice
                .splitInHalf(durationSeconds: metadata.duration)
            guard let index = jobs.firstIndex(where: { $0.id == id }),
                  jobs[index].stage == .queued,
                  jobs[index].sourceSlice == nil
            else {
                return
            }

            let splitJobs = slices.map { slice in
                var splitJob = TranscriptionJob(
                    sourcePath: job.sourcePath,
                    snapshot: job.snapshot,
                    sourceSlice: slice
                )
                splitJob.logLines.append(
                    "由已加入佇列的來源切分，將依序處理：\(slice.displayName)。"
                )
                return splitJob
            }
            jobs.replaceSubrange(index...index, with: splitJobs)
            persistJobs()
            // This action is intentionally the one-click variant of the
            // manual start button: the first slice begins immediately and
            // the second remains ordered behind it in the queue.
            startQueuedJobs()
        } catch {
            alert = UserFacingAlert(
                title: "無法切分音檔",
                message: error.localizedDescription
            )
        }
    }

    func chooseAndMergeTranscriptFiles() {
        let panel = NSOpenPanel()
        panel.title = "選擇要合併的文字稿"
        panel.prompt = "合併文字稿"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.allowedContentTypes = [.plainText]

        if let lastInputDirectory = settings.lastInputDirectory {
            panel.directoryURL = URL(fileURLWithPath: lastInputDirectory, isDirectory: true)
        }

        guard panel.runModal() == .OK else {
            return
        }

        do {
            let result = try TranscriptMerger.merge(panel.urls)
            NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
            alert = UserFacingAlert(
                title: "文字稿已合併",
                message: "已依分段編號排序並產生新檔：\n\(result.outputURL.path)\n\n原始 TXT 未被覆寫。"
            )
        } catch {
            alert = UserFacingAlert(
                title: "無法合併文字稿",
                message: error.localizedDescription
            )
        }
    }

    func addFiles(_ urls: [URL], allowingDuplicates: Bool = false) {
        guard !urls.isEmpty else {
            return
        }

        var accepted: [URL] = []
        var unsupported: [URL] = []
        var duplicates: [URL] = []
        var seenIncoming = Set<String>()
        let queuedPaths = Set(
            jobs
                .filter { !$0.stage.isTerminal }
                .map { normalizedPath($0.sourceURL) }
        )

        for url in urls {
            let normalizedURL = url.standardizedFileURL
            let key = normalizedPath(normalizedURL)
            let supported = normalizedURL.isFileURL
                && AudioProbeService.supportedExtensions.contains(
                    normalizedURL.pathExtension.lowercased()
                )

            guard supported else {
                unsupported.append(normalizedURL)
                continue
            }

            if !allowingDuplicates,
               queuedPaths.contains(key) || !seenIncoming.insert(key).inserted {
                duplicates.append(normalizedURL)
            } else {
                seenIncoming.insert(key)
                accepted.append(normalizedURL)
            }
        }

        if !unsupported.isEmpty {
            let names = unsupported.map(\.lastPathComponent).joined(separator: "、")
            alert = UserFacingAlert(
                title: "有些檔案未加入",
                message: "僅支援 M4A、MP3、WAV、AAC 與 FLAC：\(names)"
            )
        }

        enqueueValidatedFiles(accepted)

        if !duplicates.isEmpty {
            pendingDuplicateURLs = duplicates
            isDuplicateConfirmationPresented = true
        }
    }

    func confirmDuplicateFiles() {
        let duplicates = pendingDuplicateURLs
        pendingDuplicateURLs.removeAll()
        isDuplicateConfirmationPresented = false
        addFiles(duplicates, allowingDuplicates: true)
    }

    func discardDuplicateFiles() {
        pendingDuplicateURLs.removeAll()
        isDuplicateConfirmationPresented = false
    }

    // MARK: - Queue control

    func startQueuedJobs() {
        queuePausedForEnvironment = false
        manualDrainRequested = true
        scheduleQueueIfNeeded()
    }

    var isWaitingForStartup: Bool {
        manualDrainRequested && hasQueuedJobs && isGoogleAIStudioCredentialLoading
    }

    func cancelPendingStart() {
        manualDrainRequested = false
    }

    func cancelCurrentJob() {
        guard let activeJobID else {
            return
        }
        cancellationRequested.insert(activeJobID)
        appendLog("正在取消工作…", to: activeJobID)
        activeExecutionTask?.cancel()
        activeEngine?.cancelCurrentJob()
    }

    func removeQueuedJob(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.stage == .queued else {
            return
        }
        jobs.removeAll(where: { $0.id == id })
        if !hasQueuedJobs && activeJobID == nil { manualDrainRequested = false }
        persistJobs()
    }

    func retryJob(
        _ id: UUID,
        usingCurrentSettings: Bool = false,
        permittingMissingPrompt: Bool = false
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        let oldJob = jobs[index]
        guard oldJob.stage.isTerminal else {
            return
        }
        if oldJob.networkRecovery?.state == .paused {
            if usingCurrentSettings {
                cancelNetworkPausedJob(id)
                enqueueValidatedJobs([(url: oldJob.sourceURL, sourceSlice: oldJob.sourceSlice)])
            } else {
                resumeNetworkPausedJob(id)
            }
            return
        }

        if usingCurrentSettings {
            enqueueValidatedJobs([
                (url: oldJob.sourceURL, sourceSlice: oldJob.sourceSlice)
            ])
            return
        }

        // Preserve every original semantic/runtime choice. Credentials are
        // injected from Keychain only for the transient execution copy.
        let snapshot = oldJob.snapshot.withGoogleAIStudioAPIKey(nil)

        var retry = TranscriptionJob(
            sourcePath: oldJob.sourcePath,
            snapshot: snapshot,
            sourceSlice: oldJob.sourceSlice
        )
        retry.logLines.append("工作重試。")
        jobs.insert(retry, at: min(index + 1, jobs.count))
        if permittingMissingPrompt {
            allowMissingPrompt.insert(retry.id)
        }
        persistJobs()
        scheduleQueueIfNeeded()
    }

    func canResumeCloudJob(_ job: TranscriptionJob) -> Bool {
        CloudResumeCheckpointLoader.containsUsableCheckpoint(for: job, paths: paths)
    }

    func cloudResumeAvailability(_ job: TranscriptionJob) async -> Bool {
        let paths = paths
        return await Task.detached(priority: .utility) {
            CloudResumeCheckpointLoader.containsUsableCheckpoint(for: job, paths: paths)
        }.value
    }

    func canResumeLocalQwenJob(_ job: TranscriptionJob) -> Bool {
        guard job.snapshot.backendType == .localQwen,
              job.stage == .failed
                || job.stage == .cancelled
                || job.stage == .interrupted,
              let recoveryDirectory = job.failure?.recoveryDirectory
        else {
            return false
        }
        let directory = URL(
            fileURLWithPath: recoveryDirectory,
            isDirectory: true
        )
        return LocalChunkCheckpoint.containsUsableCheckpoint(
            in: directory,
            fileManager: fileManager
        )
    }

    func resumeCloudJobFromCheckpoint(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        let oldJob = jobs[index]
        if oldJob.networkRecovery?.state == .paused {
            resumeNetworkPausedJob(id)
            return
        }
        guard canResumeCloudJob(oldJob),
              let recoveryDirectory = oldJob.failure?.recoveryDirectory
        else {
            alert = UserFacingAlert(
                title: "沒有可續跑的片段",
                message: "這筆工作沒有通過基本檢查的雲端片段檢查點。"
            )
            return
        }
        guard fileManager.fileExists(atPath: oldJob.sourcePath) else {
            alert = UserFacingAlert(
                title: "來源錄音不存在",
                message: "找不到原始錄音，無法重新建立尚未完成的音訊片段。"
            )
            return
        }

        var resumed = TranscriptionJob(
            sourcePath: oldJob.sourcePath,
            snapshot: oldJob.snapshot.withGoogleAIStudioAPIKey(nil),
            sourceSlice: oldJob.sourceSlice,
            resumeFromRecoveryDirectory: recoveryDirectory
        )
        resumed.logLines.append(
            "重送未完成片段；已完成片段會先驗證並直接沿用，不會重新上傳或計費轉錄。"
        )
        jobs.insert(resumed, at: min(index + 1, jobs.count))
        persistJobs()
        manualDrainRequested = true
        scheduleQueueIfNeeded()
    }

    /// Parent state and the one continuation identity are saved in the same
    /// journal snapshot. The in-memory gate remains closed until flush succeeds.
    func resumeNetworkPausedJob(_ id: UUID) {
        guard !isTerminating, !networkContinuationInFlight.contains(id), activeJobID == nil,
              let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].stage == .interrupted,
              jobs[index].networkRecovery?.state == .paused else { return }
        let original = jobs[index]
        guard fileManager.fileExists(atPath: original.sourcePath) else {
            alert = UserFacingAlert(title: "來源錄音不存在", message: "找不到原始錄音，無法重新嘗試。")
            return
        }
        networkContinuationInFlight.insert(id)
        let continuationID: UUID
        if let existing = original.networkContinuationJobID,
           jobs.contains(where: { $0.id == existing && $0.stage == .queued }) {
            continuationID = existing
        } else {
            var continuation = TranscriptionJob(sourcePath: original.sourcePath,
                snapshot: original.snapshot.withGoogleAIStudioAPIKey(nil), sourceSlice: original.sourceSlice,
                resumeFromRecoveryDirectory: canResumeCloudJob(original) ? original.failure?.recoveryDirectory : nil)
            continuation.logLines.append("使用原工作快照重新嘗試；已完成片段會先驗證並沿用。")
            continuationID = continuation.id
            jobs[index].networkContinuationJobID = continuationID
            jobs.insert(continuation, at: jobs.firstIndex(where: { $0.stage == .queued }) ?? jobs.count)
        }
        if let parent = jobs.firstIndex(where: { $0.id == id }) { jobs[parent].networkRecovery?.state = .resolved }
        persistJobs()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.flushJobPersistence()
                self.networkContinuationInFlight.remove(id)
                guard !self.isTerminating, self.jobs.contains(where: { $0.id == continuationID && $0.stage == .queued }) else { return }
                self.manualDrainRequested = true
                self.scheduleQueueIfNeeded()
            } catch {
                if let parent = self.jobs.firstIndex(where: { $0.id == id }) { self.jobs[parent].networkRecovery?.state = .paused }
                self.networkContinuationInFlight.remove(id)
                self.manualDrainRequested = false
                self.jobPersistenceError = error.localizedDescription
                self.persistJobs()
            }
        }
    }

    func cancelNetworkPausedJob(_ id: UUID) {
        guard !networkContinuationInFlight.contains(id),
              let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].stage == .interrupted, jobs[index].networkRecovery != nil else { return }
        manualDrainRequested = false
        let continuationID = jobs[index].networkContinuationJobID
        jobs[index].stage = .cancelled
        jobs[index].networkRecovery = nil
        if let continuationID { jobs.removeAll { $0.id == continuationID && $0.stage == .queued } }
        persistJobs()
    }

    func resumeLocalQwenJobFromCheckpoint(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        let oldJob = jobs[index]
        guard canResumeLocalQwenJob(oldJob),
              let recoveryDirectory = oldJob.failure?.recoveryDirectory
        else {
            alert = UserFacingAlert(
                title: "沒有可續跑的 Qwen chunk",
                message: "這筆工作沒有通過基本檢查的本機 chunk checkpoint。"
            )
            return
        }
        guard fileManager.fileExists(atPath: oldJob.sourcePath) else {
            alert = UserFacingAlert(
                title: "來源錄音不存在",
                message: "找不到原始錄音，無法重建尚未完成的音訊片段。"
            )
            return
        }

        var resumed = TranscriptionJob(
            sourcePath: oldJob.sourcePath,
            snapshot: oldJob.snapshot.withGoogleAIStudioAPIKey(nil),
            sourceSlice: oldJob.sourceSlice,
            resumeFromRecoveryDirectory: recoveryDirectory
        )
        resumed.logLines.append(
            "從本機 Qwen chunk checkpoint 續跑；相容的已完成 chunk 不會重新推論。"
        )
        jobs.insert(resumed, at: min(index + 1, jobs.count))
        persistJobs()
        manualDrainRequested = true
        scheduleQueueIfNeeded()
    }

    func retryWithoutGlossaryPrompt() {
        guard let jobID = promptConsentJobID else {
            return
        }
        promptConsentJobID = nil
        isPromptConsentPresented = false
        queuePausedForPromptConsent = false
        retryJob(jobID, permittingMissingPrompt: true)
        if resumeQueueAfterPromptConsent {
            manualDrainRequested = true
            scheduleQueueIfNeeded()
        }
        resumeQueueAfterPromptConsent = false
    }

    func declineRetryWithoutGlossaryPrompt() {
        promptConsentJobID = nil
        isPromptConsentPresented = false
        queuePausedForPromptConsent = false
        if resumeQueueAfterPromptConsent {
            manualDrainRequested = true
            scheduleQueueIfNeeded()
        }
        resumeQueueAfterPromptConsent = false
    }

    func revealOutput(for job: TranscriptionJob) {
        guard let path = job.outputPath else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openOutput(for job: TranscriptionJob) {
        guard let path = job.outputPath else {
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func openPartialTranscript(for job: TranscriptionJob) {
        guard let path = job.failure?.partialTranscriptPath else {
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func revealRecovery(for job: TranscriptionJob) {
        guard let path = job.failure?.recoveryDirectory else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: path, isDirectory: true)
        ])
    }

    func deleteRecovery(for job: TranscriptionJob) {
        guard let path = job.failure?.recoveryDirectory else {
            return
        }
        let root = paths.tempRecovery.standardizedFileURL.resolvingSymlinksInPath()
        let target = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard
            target.deletingLastPathComponent().path == root.path,
            target.lastPathComponent == job.id.uuidString
        else {
            alert = UserFacingAlert(
                title: "拒絕刪除",
                message: "復原資料路徑不在 record-to-text 管理的範圍內。"
            )
            return
        }

        do {
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            if let index = jobs.firstIndex(where: { $0.id == job.id }),
               let failure = jobs[index].failure {
                jobs[index].failure = JobFailure(
                    stage: failure.stage,
                    userMessage: failure.userMessage,
                    technicalDetails: failure.technicalDetails,
                    recoverable: failure.recoverable,
                    recoveryDirectory: nil
                )
                jobs[index].logLines.append("已刪除失敗時保留的復原資料。")
                persistJobs()
            }
        } catch {
            alert = UserFacingAlert(
                title: "無法刪除復原資料",
                message: error.localizedDescription
            )
        }
    }

    func revealOutput(for summary: RecentJobSummary) {
        guard let path = summary.outputPath else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openOutput(for summary: RecentJobSummary) {
        guard let path = summary.outputPath else {
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func retryRecentJob(_ summary: RecentJobSummary) {
        enqueueValidatedJobs([
            (
                url: URL(fileURLWithPath: summary.sourcePath),
                sourceSlice: summary.sourceSlice
            )
        ])
    }

    func stopAllForTermination() async {
        isTerminating = true
        manualDrainRequested = false
        let preserveNetworkQueue = queuePausedForNetwork || jobs.contains { $0.networkRecovery?.state == .waiting || $0.networkRecovery?.state == .retrying }
        for index in jobs.indices where jobs[index].stage == .queued && !preserveNetworkQueue {
            jobs[index].stage = .cancelled
            jobs[index].completedAt = Date()
        }

        flushPendingSettingsPersistence()

        if let activeJobID {
            if preserveNetworkQueue { terminatingForNetwork.insert(activeJobID) }
            cancellationRequested.insert(activeJobID)
        }

        let runningTask = queueTask
        runningTask?.cancel()
        activeExecutionTask?.cancel()
        activeEngine?.cancelCurrentJob()
        await runningTask?.value
        persistJobs()
    }

    // MARK: - Environment and onboarding

    func refreshEnvironment() {
        environmentReport = RuntimeEnvironment.inspect(
            runtimeCandidate(),
            backendType: settings.backendType,
            customGCloudPath: settings.customGCloudPath
        )
        if environmentReport?.isReady == true {
            queuePausedForEnvironment = false
            scheduleQueueIfNeeded()
        }
    }

    func refreshRecoveryScan() {
        // Always show the sheet when the user clicks the toolbar button,
        // even if there is nothing to clean up (empty state is intentional UI).
        isRecoveryScanPresented = true
        runRecoveryScan(presentIfNonEmpty: false)
    }

    func dismissRecoveryScan() {
        isRecoveryScanPresented = false
    }

    func revealRecoveryScanItem(_ item: RecoveryScanItem) {
        do {
            let target = try RecoveryScanner.validatedManagedJobDirectory(
                for: item,
                paths: paths,
                fileManager: fileManager
            )
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch {
            alert = UserFacingAlert(
                title: "拒絕開啟",
                message: error.localizedDescription
            )
        }
    }

    func requestDeleteRecoveryScanItem(_ item: RecoveryScanItem) {
        recoveryItemPendingDeletion = item
    }

    func cancelDeleteRecoveryScanItem() {
        recoveryItemPendingDeletion = nil
    }

    func confirmDeleteRecoveryScanItem() {
        guard let item = recoveryItemPendingDeletion else {
            return
        }
        recoveryItemPendingDeletion = nil
        do {
            try RecoveryScanner.deleteItem(
                item,
                paths: paths,
                fileManager: fileManager
            )
            // Clear matching job failure recovery pointer if present.
            if let jobID = item.jobID,
               let index = jobs.firstIndex(where: { $0.id == jobID }),
               let failure = jobs[index].failure,
               failure.recoveryDirectory == item.directoryPath
            {
                jobs[index].failure = JobFailure(
                    stage: failure.stage,
                    userMessage: failure.userMessage,
                    technicalDetails: failure.technicalDetails,
                    recoverable: failure.recoverable,
                    recoveryDirectory: nil
                )
                jobs[index].logLines.append("已從復原掃描刪除暫存／復原資料。")
                persistJobs()
            }
            runRecoveryScan(presentIfNonEmpty: false)
        } catch {
            alert = UserFacingAlert(
                title: "無法刪除",
                message: error.localizedDescription
            )
        }
    }

    func requestBulkCleanupNonRecoverable() {
        let count = recoveryScanReport?.items.filter {
            $0.kind == .orphaned || $0.kind == .damaged
        }.count ?? 0
        guard count > 0 else {
            return
        }
        isBulkCleanupConfirmationPresented = true
    }

    func confirmBulkCleanupNonRecoverable() {
        isBulkCleanupConfirmationPresented = false
        let targets = recoveryScanReport?.items.filter {
            $0.kind == .orphaned || $0.kind == .damaged
        } ?? []
        guard !targets.isEmpty else {
            return
        }
        do {
            let result = try RecoveryScanner.deleteItems(
                targets,
                paths: paths,
                fileManager: fileManager
            )
            runRecoveryScan(presentIfNonEmpty: false)
            if !result.failures.isEmpty {
                alert = UserFacingAlert(
                    title: "部分項目未能刪除",
                    message: "已刪除 \(result.deleted) 項；失敗 \(result.failures.count) 項。請重新掃描後再試。"
                )
            }
        } catch {
            alert = UserFacingAlert(
                title: "無法批次清理",
                message: error.localizedDescription
            )
        }
    }

    /// Re-enqueue the original source audio if it still exists on disk.
    func requeueRecoverableSource(_ item: RecoveryScanItem) {
        guard item.kind == .recoverable else {
            return
        }
        guard let sourcePath = item.sourcePath, !sourcePath.isEmpty else {
            alert = UserFacingAlert(
                title: "無法重新加入",
                message: "這筆復原資料沒有記錄來源音檔路徑。"
            )
            return
        }
        let url = URL(fileURLWithPath: sourcePath)
        guard fileManager.fileExists(atPath: url.path) else {
            alert = UserFacingAlert(
                title: "來源音檔不存在",
                message: "找不到：\(sourcePath)\n可先在 Finder 顯示復原資料，或重新選擇原始音檔。"
            )
            return
        }
        isRecoveryScanPresented = false
        enqueueValidatedJobs([(url: url, sourceSlice: item.sourceSlice)])
    }

    private func runRecoveryScan(presentIfNonEmpty: Bool) {
        let activeRecoveryDirectoryPaths = Set(
            jobs.lazy.filter { !$0.stage.isTerminal }.map { job in
                if let resumedDirectory = job.resumeFromRecoveryDirectory {
                    return URL(
                        fileURLWithPath: resumedDirectory,
                        isDirectory: true
                    ).standardizedFileURL.path
                }
                return self.paths.tempRecovery.appendingPathComponent(
                    job.id.uuidString,
                    isDirectory: true
                ).standardizedFileURL.path
            }
        )
        let scanPaths = paths
        recoveryScanTask?.cancel()
        recoveryScanGeneration += 1
        let generation = recoveryScanGeneration
        isRecoveryScanRunning = true
        recoveryScanTask = Task { [weak self] in
            let scannedReport = await Task.detached(priority: .utility) {
                StartupInventory.recoveryReport(
                    paths: scanPaths,
                    activeRecoveryDirectoryPaths:
                        activeRecoveryDirectoryPaths,
                    fileManager: FileManager()
                )
            }.value
            guard let self,
                  !Task.isCancelled,
                  generation == self.recoveryScanGeneration
            else {
                return
            }
            self.recoveryScanReport = scannedReport
            self.isRecoveryScanRunning = false
            // Don't compete with first-run onboarding sheet.
            if presentIfNonEmpty,
               !scannedReport.isEmpty,
               !self.isOnboardingPresented
            {
                self.isRecoveryScanPresented = true
            }
        }
    }

    func completeOnboarding() {
        setSetting(\.hasCompletedOnboarding, to: true)
        isOnboardingPresented = false
        if settings.showNotificationWhenCompleted {
            requestNotificationAuthorization()
        }
        if let report = recoveryScanReport, !report.isEmpty {
            isRecoveryScanPresented = true
        }
    }

    // MARK: - Queue implementation

    private func enqueueValidatedFiles(_ urls: [URL]) {
        enqueueValidatedJobs(
            urls.map { (url: $0, sourceSlice: Optional<TranscriptionSourceSlice>.none) }
        )
    }

    private func enqueueValidatedJobs(
        _ entries: [(url: URL, sourceSlice: TranscriptionSourceSlice?)]
    ) {
        guard !entries.isEmpty else {
            return
        }

        let promptResult: PromptBuildResult
        do {
            promptResult = try buildPrompt()
        } catch {
            alert = UserFacingAlert(
                title: "專有名詞無法套用",
                message: error.localizedDescription
            )
            return
        }

        let outputDirectory: String
        if settings.outputLocationMode == .askEveryTime {
            guard let selected = chooseDirectory(
                title: "選擇這批錄音的輸出資料夾",
                initialPath: settings.lastOutputDirectory ?? settings.defaultOutputDirectory
            ) else {
                return
            }
            outputDirectory = selected.path
            setSetting(\.lastOutputDirectory, to: selected.path as String?)
        } else {
            outputDirectory = settings.defaultOutputDirectory
        }

        for entry in entries {
            let url = entry.url
            let sourceSlice = entry.sourceSlice
            let snapshot = JobSnapshot(
                modelID: settings.selectedModelID,
                modelRevision: selectedModelRevision,
                glossaryID: selectedGlossary?.id,
                glossaryName: selectedGlossary?.name,
                terms: promptResult.terms,
                prompt: promptResult.prompt,
                outputLocationMode: settings.outputLocationMode,
                outputDirectory: outputDirectory,
                keepRawTranscript: settings.keepRawTranscript,
                outputFilenameSuffix: settings.resolvedOutputFilenameSuffix,
                rawFilenameSuffix: settings.resolvedRawFilenameSuffix,
                backendType: settings.backendType,
                googleAIStudioModelID: settings.googleAIStudioModelID,
                vertexAIProjectID: settings.vertexAIProjectID,
                vertexAILocation: settings.vertexAILocation,
                vertexAIModelID: settings.vertexAIModelID,
                vertexAIGCSBucket: settings.vertexAIGCSBucket,
                vertexAIIncludeSummary: settings.vertexAIIncludeSummary,
                geminiThinkingLevel: settings.geminiThinkingLevel,
                cloudFallbackPolicy: settings.cloudFallbackPolicy,
                silenceAwareCloudSegmentation:
                    settings.silenceAwareCloudSegmentation
            )
            var job = TranscriptionJob(
                sourcePath: url.standardizedFileURL.path,
                snapshot: snapshot,
                sourceSlice: sourceSlice
            )
            if let sourceSlice {
                job.logLines.append(
                    "來源切片：\(sourceSlice.displayName)，將依佇列順序逐段處理。"
                )
            }
            jobs.append(job)
        }

        pruneHistoryIfNeeded()
        persistJobs()
        // Jobs stay queued until the user presses「開始轉文字」.
    }

    private func scheduleQueueIfNeeded() {
        guard !isTerminating, queueTask == nil, hasQueuedJobs else {
            return
        }
        guard !queuePausedForEnvironment, !queuePausedForPromptConsent, !queuePausedForNetwork else {
            return
        }
        // Always require an explicit start (manualDrainRequested).
        guard manualDrainRequested else {
            return
        }

        if isGoogleAIStudioCredentialLoading {
            return
        }
        queueTask = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        while !Task.isCancelled,
              !isTerminating,
              manualDrainRequested,
              !queuePausedForEnvironment,
              !queuePausedForPromptConsent,
              !queuePausedForNetwork,
              let nextJobID = jobs.first(where: { $0.stage == .queued })?.id {
            if isGoogleAIStudioCredentialLoading {
                queueTask = nil
                return
            }
            await runJob(nextJobID)
        }

        manualDrainRequested = false
        queueTask = nil
    }

    private func runJob(_ id: UUID) async {
        guard let initialIndex = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }

        jobs[initialIndex].stage = .validating
        jobs[initialIndex].startedAt = Date()
        jobs[initialIndex].completedAt = nil
        jobs[initialIndex].failure = nil
        jobs[initialIndex].logLines.append("開始處理。")
        activeJobID = id
        persistJobs()

        do {
            // A publication intent only recovers jobs already known to the journal.
            // Do not start paid work until its identity has been saved.
            try await flushJobPersistence()
            guard var currentJob = jobs.first(where: { $0.id == id }) else {
                return
            }
            let jobRuntimeSettings = runtimeSettings(for: currentJob.snapshot)
            let runtime = try RuntimeEnvironment.resolve(
                paths: paths,
                settings: jobRuntimeSettings,
                bundledHelperURL: bundledHelperURL,
                bundledFFmpegURL: bundledFFmpegURL,
                bundledFFprobeURL: bundledFFprobeURL
            )
            let engine: TranscriptionEngine
            if let reusableEngine,
               reusableEngineRuntime == runtime
            {
                engine = reusableEngine
            } else {
                engine = engineFactory?(runtime) ?? TranscriptionEngine(runtime: runtime, paths: paths)
                reusableEngine = engine
                reusableEngineRuntime = runtime
            }
            activeEngine = engine

            if currentJob.snapshot.backendType == .googleAIStudio {
                currentJob.snapshot = currentJob.snapshot.withGoogleAIStudioAPIKey(
                    settings.googleAIStudioAPIKey
                )
            }

            let permitsMissingPrompt = allowMissingPrompt.contains(id)
            let executionTask = Task {
                try await engine.run(
                    job: currentJob,
                    offline: false,
                    allowMissingPrompt: permitsMissingPrompt,
                    persistCompletion: { [weak self] result in
                        guard let self else { return false }
                        return await self.acceptCompletedResult(result, id: id)
                    }
                ) { [weak self] update in
                    Task { @MainActor in
                        self?.apply(update, to: id)
                    }
                }
            }
            activeExecutionTask = executionTask
            let result = try await executionTask.value

            let cancellationArrivedTooLate =
                cancellationRequested.remove(id) != nil || executionTask.isCancelled
            if cancellationArrivedTooLate, let index = jobs.firstIndex(where: { $0.id == id }) {
                jobs[index].logLines.append("取消要求送達時輸出已完成，因此保留完成結果。")
            }
            _ = result
        } catch {
            if cancellationRequested.remove(id) != nil || Task.isCancelled {
                markCancelled(id, error: error)
            } else {
                markFailed(id, error: error)
                if error is RuntimeEnvironmentError {
                    queuePausedForEnvironment = true
                    if let failedJob = jobs.first(where: { $0.id == id }) {
                        refreshEnvironment(for: failedJob.snapshot)
                    } else {
                        refreshEnvironment()
                    }
                    alert = UserFacingAlert(
                        title: "轉錄環境尚未就緒",
                        message: "\(error.localizedDescription)\n\n其餘工作會留在佇列，完成環境設定後再繼續。"
                    )
                }
                if isGlossaryUnsupported(error) {
                    queuePausedForPromptConsent = true
                    resumeQueueAfterPromptConsent = manualDrainRequested
                    promptConsentJobID = id
                    isPromptConsentPresented = true
                }
            }
        }

        allowMissingPrompt.remove(id)
        activeExecutionTask = nil
        activeEngine = nil
        activeJobID = nil
        pruneHistoryIfNeeded()
        persistJobs()
        if queuePausedForNetwork {
            manualDrainRequested = false
            do { try await flushJobPersistence() }
            catch { jobPersistenceError = error.localizedDescription }
        }
    }

    func acceptCompletedResult(_ result: PipelineResult, id: UUID) async -> Bool {
        let cancellationArrivedTooLate = cancellationRequested.contains(id)
            if let index = jobs.firstIndex(where: { $0.id == id }) {
                jobs[index].stage = .completed
                jobs[index].outputCompleteness = result.containsSkippedAudio ? .hasGaps : .complete
                jobs[index].progressCurrent = nil
                jobs[index].progressTotal = nil
                jobs[index].outputPath = result.outputURL.path
                jobs[index].rawOutputPath = result.rawOutputURL?.path
                jobs[index].cloudDiagnostics = result.cloudDiagnostics
                jobs[index].cloudSegmentMetadata =
                    result.cloudSegmentMetadata.isEmpty
                        ? nil
                        : result.cloudSegmentMetadata
                jobs[index].completedAt = Date()
                jobs[index].progressUnit = nil
                if !result.incompleteCloudSegmentIndices.isEmpty {
                    let labels = result.incompleteCloudSegmentIndices
                        .map(String.init)
                        .joined(separator: "、")
                    let recoveryPath = result.recoveryDirectory?.path
                    let partialPath = result.recoveryDirectory.flatMap {
                        let candidate = $0.appendingPathComponent(
                            RecoveryScanner.partialTranscriptFileName
                        )
                        return fileManager.fileExists(atPath: candidate.path)
                            ? candidate.path
                            : nil
                    }
                    jobs[index].failure = JobFailure(
                        stage: .completed,
                        userMessage: "其餘片段已完成；第 \(labels) 段遭 Google 內容安全政策攔截，已在逐字稿標出缺口。",
                        technicalDetails:
                            "Google safety-blocked segments: \(labels)",
                        recoverable: recoveryPath != nil,
                        recoveryDirectory: recoveryPath,
                        partialTranscriptPath: partialPath
                    )
                } else if result.containsSkippedAudio {
                    jobs[index].failure = JobFailure(stage: .completed,
                        userMessage: "稿件含因 token 上限跳過的音訊；請查看逐字稿中的缺口標記。",
                        technicalDetails: "Local transcription completed with token-limit gaps.",
                        recoverable: result.recoveryDirectory != nil,
                        recoveryDirectory: result.recoveryDirectory?.path)
                } else {
                    jobs[index].failure = nil
                }
                appendCloudResultSummary(result, to: index)
                let duration = Self.durationFormatter.string(from: result.duration) ?? "—"
                if !result.incompleteCloudSegmentIndices.isEmpty {
                    let labels = result.incompleteCloudSegmentIndices
                        .map(String.init)
                        .joined(separator: "、")
                    jobs[index].logLines.append(
                        "完成，但第 \(labels) 段遭 Google 安全性攔截；其餘片段已完成。耗時 \(duration)。"
                    )
                } else if result.containsSkippedAudio {
                    jobs[index].logLines.append(
                        "完成，但有音訊片段因 token 上限跳過；請查看逐字稿中的缺口標記。耗時 \(duration)。"
                    )
                } else {
                    jobs[index].logLines.append("完成，耗時 \(duration)。")
                }
                if cancellationArrivedTooLate {
                    jobs[index].logLines.append("取消要求送達時輸出已完成，因此保留完成結果。")
                }

                let completedJob = jobs[index]
                performCompletionActions(for: completedJob)
            }
        persistJobs()
        do { try await flushJobPersistence(); return true }
        catch { jobPersistenceError = error.localizedDescription; return false }
    }

    private func apply(_ update: PipelineUpdate, to jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else {
            return
        }
        guard !jobs[index].stage.isTerminal else {
            return
        }

        switch update {
        case let .networkRecovery(recovery):
            let isTransition = jobs[index].networkRecovery?.state != recovery?.state
            jobs[index].networkRecovery = recovery?.state == .resolved ? nil : recovery
            persistJobs(urgency: isTransition ? .critical : .coalescible)
        case let .stage(stage):
            jobs[index].stage = stage
            // Keep progress bar values across stage transitions so the bar
            // does not reset to indeterminate while a long segment runs.
            if !stage.isTerminal { persistJobs(urgency: .coalescible) }
        case let .progress(current, total, unit):
            jobs[index].progressCurrent = current
            jobs[index].progressTotal = total
            jobs[index].progressUnit = unit
        case let .log(level, message):
            guard level != "heartbeat", !message.isEmpty else {
                return
            }
            appendLog(message, to: jobID)
        case let .warning(_, message):
            appendLog("警告：\(message)", to: jobID)
        }
    }

    private func appendCloudResultSummary(
        _ result: PipelineResult,
        to index: Int
    ) {
        let metadata = result.cloudSegmentMetadata
        guard !metadata.isEmpty else {
            return
        }
        let effectiveModels = CloudTranscriptionMetadataAggregator
            .uniqueEffectiveModelIDs(metadata)
        let retries = CloudTranscriptionMetadataAggregator
            .totalRetryCount(metadata)
        let usage = CloudTranscriptionMetadataAggregator.totalUsage(metadata)
        var parts = ["實際模型：\(effectiveModels.joined(separator: ", "))"]
        if retries > 0 {
            parts.append("總重試 \(retries) 次")
        }
        if let total = usage?.totalTokenCount {
            parts.append("總 token \(total)")
        }
        if let thoughts = usage?.thoughtsTokenCount {
            parts.append("thinking token \(thoughts)")
        }
        if let cost = usage?.estimatedCostUSD(modelID: effectiveModels.first ?? "") {
            parts.append("預估 \(CloudUsageMetadata.formatCostUSD(cost))")
        }
        jobs[index].logLines.append(parts.joined(separator: "；") + "。")
    }

    private func markCancelled(_ id: UUID, error: Error) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        let recoveryFailure: JobFailure?
        if jobs[index].snapshot.backendType == .localQwen {
            recoveryFailure = Self.localChunkRecoveryFailure(
                jobID: id,
                stage: .cancelled,
                paths: paths,
                fileManager: fileManager,
                technicalDetails: String(reflecting: error)
            )
        } else {
            jobs[index].cloudDiagnostics = CloudJobDiagnostics.load(manifestURL:
                paths.tempRecovery.appendingPathComponent(id.uuidString)
                    .appendingPathComponent(RecoveryScanner.segmentManifestFileName))
            recoveryFailure = Self.cancellationRecoveryFailure(
                jobID: id,
                paths: paths,
                fileManager: fileManager,
                technicalDetails: String(reflecting: error)
            )
        }
        jobs[index].stage = .cancelled
        jobs[index].progressCurrent = nil
        jobs[index].progressTotal = nil
        jobs[index].progressUnit = nil
        jobs[index].completedAt = Date()
        jobs[index].failure = recoveryFailure
        if terminatingForNetwork.remove(id) != nil {
            jobs[index].stage = .interrupted
            jobs[index].networkRecovery?.state = .paused
            jobs[index].networkRecovery?.stopReason = .appRestarted
        } else {
            jobs[index].networkRecovery = nil
        }
        if recoveryFailure == nil {
            jobs[index].logLines.append("工作已取消，未保留未完成文字。")
        } else if jobs[index].snapshot.backendType == .localQwen {
            jobs[index].logLines.append(
                "工作已取消；已保留本機 Qwen chunk checkpoint，可稍後續跑。"
            )
        } else {
            jobs[index].logLines.append(
                "工作已取消；已完成的雲端片段已保留為未完成稿，可打開或刪除。"
            )
            runRecoveryScan(presentIfNonEmpty: false)
        }
    }

    static func cancellationRecoveryFailure(
        jobID: UUID,
        paths: ApplicationPaths,
        fileManager: FileManager = .default,
        technicalDetails: String = "CancellationError"
    ) -> JobFailure? {
        let directory = paths.tempRecovery.appendingPathComponent(
            jobID.uuidString,
            isDirectory: true
        )
        let metadataURL = directory.appendingPathComponent(
            RecoveryScanner.recoveryJSONFileName
        )
        let manifestURL = directory.appendingPathComponent(
            RecoveryScanner.segmentManifestFileName
        )
        let partialURL = directory.appendingPathComponent(
            RecoveryScanner.partialTranscriptFileName
        )
        guard
            fileManager.fileExists(atPath: metadataURL.path),
            fileManager.fileExists(atPath: manifestURL.path),
            fileManager.fileExists(atPath: partialURL.path),
            (try? TextFileValidator.readNonEmptyUTF8(at: partialURL)) != nil,
            let metadataData = try? Data(contentsOf: metadataURL)
        else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard
            let metadata = try? decoder.decode(
                RecoveryScanner.RecoveryMetadata.self,
                from: metadataData
            ),
            metadata.schemaVersion >= 2,
            metadata.jobID == jobID,
            metadata.recoveryKind == "cloudCheckpoint"
        else {
            return nil
        }

        return JobFailure(
            stage: .cancelled,
            userMessage: "工作已取消；已完成的片段仍保留在這台 Mac 的 Temp-Recovery，可打開未完成稿或刪除。",
            technicalDetails: technicalDetails,
            recoverable: true,
            recoveryDirectory: directory.path,
            partialTranscriptPath: partialURL.path
        )
    }

    static func localChunkRecoveryFailure(
        jobID: UUID,
        stage: TranscriptionStage,
        paths: ApplicationPaths,
        fileManager: FileManager = .default,
        technicalDetails: String
    ) -> JobFailure? {
        let directory = paths.tempRecovery.appendingPathComponent(
            jobID.uuidString,
            isDirectory: true
        )
        guard LocalChunkCheckpoint.containsUsableCheckpoint(
            in: directory,
            fileManager: fileManager
        ) else {
            return nil
        }
        return JobFailure(
            stage: stage,
            userMessage: "Qwen 工作已停止；已保留通過基本檢查的 chunk checkpoint，可從已完成 chunk 續跑。",
            technicalDetails: technicalDetails,
            recoverable: true,
            recoveryDirectory: directory.path,
            partialTranscriptPath: nil
        )
    }

    private func markFailed(_ id: UUID, error: Error) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }

        let pipelineError = error as? PipelineExecutionError
        jobs[index].cloudDiagnostics = pipelineError?.cloudDiagnostics
        let stage = pipelineError?.stage ?? jobs[index].stage
        let recoveryDirectory = pipelineError?.recoveryDirectory?.path
        let partialTranscriptPath = recoveryDirectory.flatMap { path in
            let partialURL = URL(fileURLWithPath: path)
                .appendingPathComponent("partial-transcript.txt")
            return fileManager.fileExists(atPath: partialURL.path)
                ? partialURL.path
                : nil
        }

        jobs[index].networkRecovery = pipelineError?.networkRecovery
        jobs[index].stage = pipelineError?.networkRecovery == nil ? .failed : .interrupted
        jobs[index].progressCurrent = nil
        jobs[index].progressTotal = nil
        jobs[index].progressUnit = nil
        jobs[index].completedAt = Date()
        jobs[index].failure = JobFailure(
            stage: stage,
            userMessage: pipelineError?.networkRecovery?.message ?? error.localizedDescription,
            technicalDetails: pipelineError?.failureDiagnostic?.debugSummary ?? String(reflecting: error),
            recoverable: true,
            recoveryDirectory: recoveryDirectory,
            partialTranscriptPath: partialTranscriptPath,
            cloudDiagnostic: pipelineError?.failureDiagnostic
        )
        jobs[index].logLines.append("失敗：\(error.localizedDescription)")
    }

    private func appendLog(_ line: String, to id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        jobs[index].logLines.append(line)
        if jobs[index].logLines.count > 400 {
            jobs[index].logLines.removeFirst(jobs[index].logLines.count - 400)
        }
    }

    private func isGlossaryUnsupported(_ error: Error) -> Bool {
        if case ASRBackendError.glossaryPromptUnsupported = error {
            return true
        }
        if let pipeline = error as? PipelineExecutionError,
           case ASRBackendError.glossaryPromptUnsupported = pipeline.underlying {
            return true
        }
        return false
    }

    // MARK: - Helpers

    private func buildPrompt() throws -> PromptBuildResult {
        try PromptBuilder.build(
            commonTerms: glossaryCollection.commonTerms,
            glossaryTerms: selectedGlossary?.terms ?? [],
            temporaryTerms: TermParser.parse(settings.lastTemporaryTerms)
        )
    }

    private var selectedModelRevision: String? {
        ASRModelDescriptor.revision(forModelID: settings.selectedModelID)
    }

    private func performModelDownload(modelID: String, revision: String?) async {
        modelDownloadProgressLine = ""
        do {
            try paths.createDirectories(fileManager: fileManager)
        } catch {
            modelDownloadPhase = .failed("無法建立模型資料夾：\(error.localizedDescription)")
            return
        }

        if ModelCache.isDownloaded(
            modelID: modelID,
            revision: revision,
            modelsDirectory: paths.models,
            fileManager: fileManager
        ) {
            isSelectedModelCached = true
            modelDownloadPhase = .succeeded("App 模型目錄已有此模型。")
            modelDownloadProgressLine = ""
            return
        }

        if ModelCache.isDownloadedInDefaultCache(
            modelID: modelID,
            revision: revision,
            fileManager: fileManager
        ) {
            modelDownloadPhase = .importingLocal
            modelDownloadProgressLine = "正在從 ~/.cache/huggingface 匯入…"
            do {
                try importModelFromDefaultHFCache(modelID: modelID)
                refreshSelectedModelCacheStatus()
                if isSelectedModelCached {
                    modelDownloadPhase = .succeeded("已從本機 Hugging Face cache 匯入。")
                    modelDownloadProgressLine = ""
                    return
                }
            } catch {
                modelDownloadProgressLine =
                    "本機匯入失敗，改從網路下載：\(error.localizedDescription)"
            }
        }

        modelDownloadPhase = .downloading
        if modelDownloadProgressLine.isEmpty {
            modelDownloadProgressLine = "正在下載 \(modelID)…"
        }

        let runtime = runtimeCandidate()
        guard fileManager.isExecutableFile(atPath: runtime.python.path) else {
            modelDownloadPhase = .failed(
                "找不到 Python（\(runtime.python.path)）。請開啟 Developer Mode 並準備 mlx-audio-env。"
            )
            return
        }

        let script = """
        import sys
        from huggingface_hub import snapshot_download

        repo_id = sys.argv[1]
        revision = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None
        kwargs = {"repo_id": repo_id}
        if revision:
            kwargs["revision"] = revision
        path = snapshot_download(**kwargs)
        print(path)
        """

        let environment = modelDownloadEnvironment(modelsDirectory: paths.models)
        var arguments = ["-u", "-c", script, modelID]
        if let revision, !revision.isEmpty {
            arguments.append(revision)
        } else {
            arguments.append("")
        }

        do {
            _ = try await modelDownloadRunner.run(
                executableURL: runtime.python,
                arguments: arguments,
                environment: environment,
                requireSuccess: true,
                stdoutLineHandler: { [weak self] line in
                    Task { @MainActor in
                        self?.modelDownloadProgressLine = line
                    }
                },
                stderrLineHandler: { [weak self] line in
                    Task { @MainActor in
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else {
                            return
                        }
                        self?.modelDownloadProgressLine = trimmed
                    }
                }
            )
            refreshSelectedModelCacheStatus()
            if isSelectedModelCached {
                modelDownloadPhase = .succeeded("模型已下載到 App 模型目錄。")
            } else {
                modelDownloadPhase = .failed(
                    "下載程序結束，但 App 模型目錄仍找不到完整 snapshot。請再試一次。"
                )
            }
        } catch is CancellationError {
            modelDownloadPhase = .idle
            modelDownloadProgressLine = "已取消下載。"
        } catch {
            if Task.isCancelled {
                modelDownloadPhase = .idle
                modelDownloadProgressLine = "已取消下載。"
            } else {
                modelDownloadPhase = .failed(error.localizedDescription)
            }
        }
        refreshSelectedModelCacheStatus()
    }

    private func importModelFromDefaultHFCache(modelID: String) throws {
        let source = ModelCache.repositoryDirectory(
            modelID: modelID,
            hubRoot: ModelCache.defaultHuggingFaceHub(fileManager: fileManager)
        )
        let destinationRoot = ModelCache.hubRoot(modelsDirectory: paths.models)
        let destination = ModelCache.repositoryDirectory(
            modelID: modelID,
            hubRoot: destinationRoot
        )

        guard fileManager.fileExists(atPath: source.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        try fileManager.createDirectory(
            at: destinationRoot,
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func modelDownloadEnvironment(modelsDirectory: URL) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in [
            "HOME",
            "TMPDIR",
            "LANG",
            "LC_ALL",
            "TZ",
            "SSL_CERT_FILE",
            "SSL_CERT_DIR",
            "HF_TOKEN",
            "HUGGING_FACE_HUB_TOKEN"
        ] {
            if let value = inherited[key], !value.isEmpty {
                environment[key] = value
            }
        }
        let pathParts = [
            runtimeCandidate().python.deletingLastPathComponent().path,
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        environment["PATH"] = pathParts.joined(separator: ":")
        environment["HF_HOME"] = modelsDirectory.path
        environment["HF_HUB_CACHE"] = ModelCache.hubRoot(modelsDirectory: modelsDirectory).path
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONUTF8"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["HF_HUB_DISABLE_PROGRESS_BARS"] = "0"
        return environment
    }

    private func chooseDirectory(title: String, initialPath: String?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "選擇"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let initialPath, !initialPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: initialPath, isDirectory: true)
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func uniqueGlossaryName(_ requestedName: String) -> String {
        let base = requestedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "新詞庫"
            : requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = Set(glossaryCollection.glossaries.map(\.name))
        guard existing.contains(base) else {
            return base
        }

        var index = 2
        while existing.contains("\(base) \(index)") {
            index += 1
        }
        return "\(base) \(index)"
    }

    private var bundledFFmpegURL: URL? {
        bundledAuxiliaryExecutable(named: "ffmpeg")
    }

    private var bundledFFprobeURL: URL? {
        bundledAuxiliaryExecutable(named: "ffprobe")
    }

    private func bundledAuxiliaryExecutable(named name: String) -> URL? {
        let candidates: [URL] = [
            Bundle.main.url(forAuxiliaryExecutable: name),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/\(name)", isDirectory: false),
            URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
                .appendingPathComponent("Helpers/\(name)")
        ].compactMap { $0 }

        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    private var bundledHelperURL: URL? {
        let helperName = CPUArchitecture.current == .x86_64
            ? "qwen_asr_transformers_runner"
            : "qwen_asr_mlx_runner"
        let resourceBundleName = "record-to-text_RecordToTextApp"
        let candidates = [
            Bundle.main.resourceURL?
                .appendingPathComponent("\(resourceBundleName).bundle"),
            Bundle.main.bundleURL
                .appendingPathComponent("\(resourceBundleName).bundle"),
            URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
                .appendingPathComponent("\(resourceBundleName).bundle")
        ].compactMap { $0 }

        for candidate in candidates {
            if let bundle = Bundle(url: candidate),
               let helper = bundle.url(forResource: helperName, withExtension: "py") {
                return helper
            }
        }
        return nil
    }

    private func runtimeCandidate() -> ResolvedRuntime {
        RuntimeEnvironment.candidate(
            paths: paths,
            settings: settings,
            bundledHelperURL: bundledHelperURL,
            bundledFFmpegURL: bundledFFmpegURL,
            bundledFFprobeURL: bundledFFprobeURL,
            fileManager: fileManager
        )
    }

    /// Resolves a queued job against the settings captured when it was added,
    /// so changing the UI cannot switch its backend or runtime underneath it.
    private func runtimeSettings(for snapshot: JobSnapshot) -> AppSettings {
        settings.applyingRuntimeConfiguration(from: snapshot)
    }

    private func refreshEnvironment(for snapshot: JobSnapshot) {
        let resolved = runtimeSettings(for: snapshot)
        let candidate = RuntimeEnvironment.candidate(
            paths: paths,
            settings: resolved,
            bundledHelperURL: bundledHelperURL,
            bundledFFmpegURL: bundledFFmpegURL,
            bundledFFprobeURL: bundledFFprobeURL,
            fileManager: fileManager
        )
        environmentReport = RuntimeEnvironment.inspect(
            candidate,
            backendType: snapshot.backendType,
            customGCloudPath: resolved.customGCloudPath
        )
    }

    private static func normalizedAPIKey(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private func performCompletionActions(for job: TranscriptionJob) {
        if settings.showNotificationWhenCompleted {
            let content = UNMutableNotificationContent()
            content.title = "轉錄\(job.resolvedOutputCompleteness.completionLabel)"
            content.body = job.resolvedOutputCompleteness == .hasGaps
                ? "\(job.displayName) 已產生文字檔，但含缺口，請查看工作紀錄。"
                : "\(job.displayName) 已產生台灣繁體文字檔。"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: job.id.uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }

        if settings.revealInFinderWhenCompleted {
            revealOutput(for: job)
        }
        if settings.openTextWhenCompleted {
            openOutput(for: job)
        }
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { [weak self] granted, error in
            guard !granted || error != nil else {
                return
            }
            Task { @MainActor in
                self?.alert = UserFacingAlert(
                    title: "通知尚未開啟",
                    message: error?.localizedDescription
                        ?? "可稍後到「系統設定・通知」允許 record-to-text 顯示完成通知。"
                )
            }
        }
    }

    @discardableResult
    private func persistSettings() -> Bool {
        if legacySettingsCredentialMigrationPending,
           !ensureLegacyCredentialStoreIsSynchronized()
        {
            return false
        }
        do {
            try saveSettingsValue(settings)
            legacySettingsCredentialMigrationPending = false
            clearLegacyCredentialSynchronizationIfFinished()
            return true
        } catch {
            alert = UserFacingAlert(
                title: "無法儲存設定",
                message: error.localizedDescription
            )
            return false
        }
    }

    private func persistGlossaries() {
        do {
            try glossaryRepository.save(glossaryCollection)
        } catch {
            alert = UserFacingAlert(
                title: "無法儲存詞庫",
                message: error.localizedDescription
            )
        }
    }

    @discardableResult
    func persistJobs(urgency: JobPersistenceCoordinator.Urgency = .critical) -> Bool {
        guard !isGoogleAIStudioCredentialLoading, !jobPersistenceLoadBlocked else {
            jobPersistenceDeferred = true
            return false
        }
        if legacyLedgerCredentialMigrationPending,
           !ensureLegacyCredentialStoreIsSynchronized() {
            jobPersistenceDeferred = true
            return false
        }
        jobPersistenceDeferred = false
        // Force lazy initialization before advancing the first revision.
        let coordinator = jobPersistence
        persistenceRevision += 1
        let terminal = jobs.filter { $0.stage.isTerminal }.map(RecentJobSummary.init(job:))
        let terminalIDs = Set(terminal.map(\.id))
        recentJobs = recentJobs.filter { !terminalIDs.contains($0.id) } + terminal
        let snapshot = PersistenceSnapshot(revision: persistenceRevision, jobs: jobs,
            recentJobs: recentJobs, recentHistoryLimit: max(settings.recentJobLimit, 0))
        let migrating = legacyLedgerCredentialMigrationPending
        let effectiveUrgency: JobPersistenceCoordinator.Urgency = pendingPersistenceSubmission?.1 == .critical ? .critical : urgency
        pendingPersistenceSubmission = (snapshot, effectiveUrgency)
        if persistenceSubmission == nil {
            persistenceSubmission = Task { [weak self] in
                guard let self else { return }
                while let (next, nextUrgency) = self.pendingPersistenceSubmission {
                    self.pendingPersistenceSubmission = nil
                    await coordinator.submit(next, urgency: nextUrgency)
                    if self.legacyLedgerCredentialMigrationPending {
                        do {
                            try await coordinator.flush(throughRevision: next.revision)
                            self.legacyLedgerCredentialMigrationPending = false
                            self.clearLegacyCredentialSynchronizationIfFinished()
                        } catch { self.jobPersistenceError = error.localizedDescription }
                    }
                }
                self.persistenceSubmission = nil
            }
        }
        return !migrating
    }

    private func finishLegacyLedgerMigration() async -> Bool {
        guard legacyLedgerCredentialMigrationPending else { return true }
        guard ensureLegacyCredentialStoreIsSynchronized() else { return false }
        persistJobs()
        do { try await flushJobPersistence() } catch { return false }
        return !legacyLedgerCredentialMigrationPending
    }

    func flushJobPersistence() async throws {
        guard !jobPersistenceLoadBlocked else { throw CocoaError(.fileReadCorruptFile) }
        guard !jobPersistenceDeferred else { throw CocoaError(.fileWriteUnknown) }
        let submission = persistenceSubmission
        let target = persistenceRevision
        let coordinator = jobPersistence
        try await CloudSegmentBudget(limit: .seconds(5)).withDeadline(stage: "persistence") {
            await submission?.value
            try await coordinator.flush(throughRevision: target)
        }
    }

    func saveLatestJobsForTermination() async throws {
        persistJobs()
        try await flushJobPersistence()
    }

    func retryJobPersistence() async {
        persistJobs()
        do { try await flushJobPersistence(); jobPersistenceError = nil }
        catch { jobPersistenceError = error.localizedDescription }
    }

    /// Before redacting the only legacy JSON copy, require a confirmed
    /// Keychain backup. If Keychain is unavailable, the old file remains
    /// byte-for-byte untouched so the next launch can retry without losing the
    /// credential.
    private func ensureLegacyCredentialStoreIsSynchronized(
        credential explicitCredential: String? = nil
    ) -> Bool {
        guard !isGoogleAIStudioCredentialLoading else { return false }
        if credentialStoreSynchronizedForLegacyMigration {
            return true
        }
        do {
            let credential = explicitCredential ?? Self.normalizedAPIKey(
                settings.googleAIStudioAPIKey
            )
            try credentialStore.saveAPIKey(credential)
            credentialStoreSynchronizedForLegacyMigration = true
            googleAIStudioCredentialStorageState = credential == nil
                ? .absent
                : .stored
            return true
        } catch {
            alert = UserFacingAlert(
                title: "舊版 API Key 尚未遷移",
                message: "Keychain 仍無法儲存 API Key，因此 App 沒有改寫含舊版憑證的 JSON，以避免遺失：\(error.localizedDescription)"
            )
            return false
        }
    }

    private func clearLegacyCredentialSynchronizationIfFinished() {
        if !legacySettingsCredentialMigrationPending,
           !legacyLedgerCredentialMigrationPending
        {
            credentialStoreSynchronizedForLegacyMigration = false
        }
    }

    private func pruneHistoryIfNeeded() {
        let limit = max(settings.recentJobLimit, 0)
        jobs = JobRetentionPolicy.inMemoryJobs(
            jobs,
            terminalHistoryLimit: limit
        )
        recentJobs = JobRetentionPolicy.recentSummaries(
            recentJobs,
            limit: limit
        )
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

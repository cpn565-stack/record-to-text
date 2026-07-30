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

    @Published var alert: UserFacingAlert?
    @Published var isPromptPreviewPresented = false
    @Published var isGlossaryManagerPresented = false
    @Published var isEnvironmentPresented = false
    @Published var isOnboardingPresented: Bool
    @Published var isDuplicateConfirmationPresented = false
    @Published var isPromptConsentPresented = false

    private let paths: ApplicationPaths
    private let settingsRepository: JSONRepository<AppSettings>
    private let glossaryRepository: JSONRepository<GlossaryCollection>
    private let recentJobsRepository: JSONRepository<RecentJobCollection>
    private let jobLedgerRepository: JSONRepository<JobLedgerCollection>
    private let fileManager: FileManager
    private let modelDownloadRunner = ProcessRunner()

    private var queueTask: Task<Void, Never>?
    private var activeExecutionTask: Task<PipelineResult, Error>?
    private var activeEngine: TranscriptionEngine?
    private var modelDownloadTask: Task<Void, Never>?
    private var manualDrainRequested = false
    private var pendingDuplicateURLs: [URL] = []
    private var promptConsentJobID: UUID?
    private var cancellationRequested = Set<UUID>()
    private var allowMissingPrompt = Set<UUID>()
    private var queuePausedForPromptConsent = false
    private var resumeQueueAfterPromptConsent = false
    private var queuePausedForEnvironment = false

    init(
        paths: ApplicationPaths = .live(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.settingsRepository = JSONRepository(url: paths.settings)
        self.glossaryRepository = JSONRepository(url: paths.glossaries)
        self.recentJobsRepository = JSONRepository(url: paths.recentJobs)
        self.jobLedgerRepository = JSONRepository(url: paths.jobLedger)

        var startupMessages: [String] = []
        do {
            try paths.createDirectories(fileManager: fileManager)
        } catch {
            startupMessages.append("無法建立 App 資料夾：\(error.localizedDescription)")
        }

        let loadedSettings: AppSettings
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

        let loadedRecentJobs: RecentJobCollection
        do {
            loadedRecentJobs = try recentJobsRepository.load(default: RecentJobCollection())
        } catch {
            loadedRecentJobs = RecentJobCollection()
            startupMessages.append("最近工作無法讀取：\(error.localizedDescription)")
        }

        var loadedLedger: JobLedgerCollection
        do {
            loadedLedger = try jobLedgerRepository.load(default: JobLedgerCollection())
        } catch {
            loadedLedger = JobLedgerCollection()
            startupMessages.append("未完成工作記錄無法讀取：\(error.localizedDescription)")
        }

        var summaries = loadedRecentJobs.jobs
        var didInterruptJobs = false
        for index in loadedLedger.jobs.indices where !loadedLedger.jobs[index].stage.isTerminal {
            loadedLedger.jobs[index].stage = .interrupted
            loadedLedger.jobs[index].completedAt = Date()
            loadedLedger.jobs[index].logLines.append("App 上次結束時工作尚未完成。")
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

        if !startupMessages.isEmpty {
            self.alert = UserFacingAlert(
                title: "部分資料未能載入",
                message: startupMessages.joined(separator: "\n\n")
            )
        }

        if didInterruptJobs {
            persistJobs()
        }

        refreshSelectedModelCacheStatus()
    }

    deinit {
        queueTask?.cancel()
        activeExecutionTask?.cancel()
        activeEngine?.cancelCurrentJob()
        modelDownloadTask?.cancel()
        modelDownloadRunner.cancelCurrent()
    }

    // MARK: - Read-only presentation state

    var selectedGlossary: GlossaryPreset? {
        guard let selectedID = settings.lastSelectedGlossaryID else {
            return nil
        }
        return glossaryCollection.glossaries.first(where: { $0.id == selectedID })
    }

    var selectedModelName: String {
        ASRModelDescriptor.descriptor(id: settings.selectedModelID)?.displayName
            ?? settings.selectedModelID
    }

    var selectedModelDetail: String? {
        ASRModelDescriptor.descriptor(id: settings.selectedModelID)?.detail
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

    func setSetting<Value>(
        _ keyPath: WritableKeyPath<AppSettings, Value>,
        to value: Value
    ) {
        var updated = settings
        updated[keyPath: keyPath] = value
        settings = updated
        persistSettings()

        if settings.autoStartAfterSelection {
            scheduleQueueIfNeeded()
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

    func refreshSelectedModelCacheStatus() {
        let modelID = settings.selectedModelID
        let revision = selectedModelRevision
        isSelectedModelCached = ModelCache.isDownloaded(
            modelID: modelID,
            revision: revision,
            modelsDirectory: paths.models,
            fileManager: fileManager
        )
        isSelectedModelInDefaultHFCache = ModelCache.isDownloadedInDefaultCache(
            modelID: modelID,
            revision: revision,
            fileManager: fileManager
        )
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

    func resetSettings(keepGlossaries: Bool) {
        settings = AppSettings.defaultValue(fileManager: fileManager)
        if !keepGlossaries {
            glossaryCollection = GlossaryCollection()
            persistGlossaries()
        }
        persistSettings()
        refreshEnvironment()
    }

    func clearRecentJobs() {
        jobs.removeAll(where: { $0.stage.isTerminal })
        recentJobs.removeAll()
        persistJobs()
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

        if usingCurrentSettings {
            addFiles([oldJob.sourceURL], allowingDuplicates: true)
            return
        }

        var retry = TranscriptionJob(
            sourcePath: oldJob.sourcePath,
            snapshot: oldJob.snapshot
        )
        retry.logLines.append("沿用工作 \(oldJob.id.uuidString) 的 Snapshot 重試。")
        jobs.insert(retry, at: min(index + 1, jobs.count))
        if permittingMissingPrompt {
            allowMissingPrompt.insert(retry.id)
        }
        persistJobs()
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
                jobs[index].logLines.append("已刪除失敗時保留的 WAV。")
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
        addFiles(
            [URL(fileURLWithPath: summary.sourcePath)],
            allowingDuplicates: true
        )
    }

    func stopAllForTermination() async {
        for index in jobs.indices where jobs[index].stage == .queued {
            jobs[index].stage = .cancelled
            jobs[index].completedAt = Date()
        }

        if let activeJobID {
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
        environmentReport = RuntimeEnvironment.inspect(runtimeCandidate())
        if environmentReport?.isReady == true {
            queuePausedForEnvironment = false
            scheduleQueueIfNeeded()
        }
    }

    func completeOnboarding() {
        setSetting(\.hasCompletedOnboarding, to: true)
        isOnboardingPresented = false
        if settings.showNotificationWhenCompleted {
            requestNotificationAuthorization()
        }
    }

    // MARK: - Queue implementation

    private func enqueueValidatedFiles(_ urls: [URL]) {
        guard !urls.isEmpty else {
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

        for url in urls {
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
                rawFilenameSuffix: settings.resolvedRawFilenameSuffix
            )
            jobs.append(
                TranscriptionJob(
                    sourcePath: url.standardizedFileURL.path,
                    snapshot: snapshot
                )
            )
        }

        pruneHistoryIfNeeded()
        persistJobs()
        scheduleQueueIfNeeded()
    }

    private func scheduleQueueIfNeeded() {
        guard queueTask == nil, hasQueuedJobs else {
            return
        }
        guard !queuePausedForEnvironment, !queuePausedForPromptConsent else {
            return
        }
        guard settings.autoStartAfterSelection || manualDrainRequested else {
            return
        }

        queueTask = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        while !Task.isCancelled,
              !queuePausedForEnvironment,
              !queuePausedForPromptConsent,
              let nextJobID = jobs.first(where: { $0.stage == .queued })?.id {
            await runJob(nextJobID)
        }

        manualDrainRequested = false
        queueTask = nil

        if !Task.isCancelled,
           !queuePausedForPromptConsent,
           !queuePausedForEnvironment,
           settings.autoStartAfterSelection,
           hasQueuedJobs {
            scheduleQueueIfNeeded()
        }
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
            let runtime = try RuntimeEnvironment.resolve(
                paths: paths,
                settings: settings,
                bundledHelperURL: bundledHelperURL
            )
            let engine = TranscriptionEngine(runtime: runtime, paths: paths)
            activeEngine = engine

            guard let currentJob = jobs.first(where: { $0.id == id }) else {
                return
            }

            let permitsMissingPrompt = allowMissingPrompt.contains(id)
            let executionTask = Task {
                try await engine.run(
                    job: currentJob,
                    offline: false,
                    allowMissingPrompt: permitsMissingPrompt
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
            if let index = jobs.firstIndex(where: { $0.id == id }) {
                jobs[index].stage = .completed
                jobs[index].progressCurrent = nil
                jobs[index].progressTotal = nil
                jobs[index].outputPath = result.outputURL.path
                jobs[index].rawOutputPath = result.rawOutputURL?.path
                jobs[index].completedAt = Date()
                jobs[index].logLines.append(
                    "完成，耗時 \(Self.durationFormatter.string(from: result.duration) ?? "—")。"
                )
                if cancellationArrivedTooLate {
                    jobs[index].logLines.append("取消要求送達時輸出已完成，因此保留完成結果。")
                }

                let completedJob = jobs[index]
                performCompletionActions(for: completedJob)
            }
        } catch {
            if cancellationRequested.remove(id) != nil || Task.isCancelled {
                markCancelled(id)
            } else {
                markFailed(id, error: error)
                if error is RuntimeEnvironmentError {
                    queuePausedForEnvironment = true
                    refreshEnvironment()
                    alert = UserFacingAlert(
                        title: "轉錄環境尚未就緒",
                        message: "\(error.localizedDescription)\n\n其餘工作會留在佇列，完成環境設定後再繼續。"
                    )
                }
                if isGlossaryUnsupported(error) {
                    queuePausedForPromptConsent = true
                    resumeQueueAfterPromptConsent =
                        settings.autoStartAfterSelection || manualDrainRequested
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
    }

    private func apply(_ update: PipelineUpdate, to jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else {
            return
        }
        guard !jobs[index].stage.isTerminal else {
            return
        }

        switch update {
        case let .stage(stage):
            jobs[index].stage = stage
            // Keep progress bar values across stage transitions so the bar
            // does not reset to indeterminate while a long segment runs.
            persistJobs()
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

    private func markCancelled(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        jobs[index].stage = .cancelled
        jobs[index].progressCurrent = nil
        jobs[index].progressTotal = nil
        jobs[index].progressUnit = nil
        jobs[index].completedAt = Date()
        jobs[index].failure = nil
        jobs[index].logLines.append("工作已取消。")
    }

    private func markFailed(_ id: UUID, error: Error) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }

        let pipelineError = error as? PipelineExecutionError
        let stage = pipelineError?.stage ?? jobs[index].stage
        let recoveryDirectory = pipelineError?.recoveryDirectory?.path

        jobs[index].stage = .failed
        jobs[index].progressCurrent = nil
        jobs[index].progressTotal = nil
        jobs[index].progressUnit = nil
        jobs[index].completedAt = Date()
        jobs[index].failure = JobFailure(
            stage: stage,
            userMessage: error.localizedDescription,
            technicalDetails: String(reflecting: error),
            recoverable: true,
            recoveryDirectory: recoveryDirectory
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
        let releaseBin = paths.runtimes
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        let helperFilename = CPUArchitecture.current == .x86_64
            ? "qwen_asr_transformers_runner.py"
            : "qwen_asr_mlx_runner.py"

        if settings.developerMode {
            let prefix = CPUArchitecture.current == .x86_64
                ? "/usr/local/bin"
                : "/opt/homebrew/bin"
            let defaultEnvironmentName = CPUArchitecture.current == .x86_64
                ? "record-to-text-intel-env"
                : "mlx-audio-env"
            let python = settings.customPythonPath
                ?? fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("\(defaultEnvironmentName)/bin/python")
                    .path
            let helper = settings.customHelperPath
                ?? bundledHelperURL?.path
                ?? releaseBin.appendingPathComponent(helperFilename).path
            return ResolvedRuntime(
                python: URL(fileURLWithPath: python),
                ffmpeg: URL(fileURLWithPath: "\(prefix)/ffmpeg"),
                ffprobe: URL(fileURLWithPath: "\(prefix)/ffprobe"),
                opencc: URL(fileURLWithPath: "\(prefix)/opencc"),
                helper: URL(fileURLWithPath: helper),
                isDeveloperRuntime: true
            )
        }

        return ResolvedRuntime(
            python: releaseBin.appendingPathComponent("python"),
            ffmpeg: releaseBin.appendingPathComponent("ffmpeg"),
            ffprobe: releaseBin.appendingPathComponent("ffprobe"),
            opencc: releaseBin.appendingPathComponent("opencc"),
            helper: releaseBin.appendingPathComponent(helperFilename),
            isDeveloperRuntime: false
        )
    }

    private func performCompletionActions(for job: TranscriptionJob) {
        if settings.showNotificationWhenCompleted {
            let content = UNMutableNotificationContent()
            content.title = "轉錄完成"
            content.body = "\(job.displayName) 已產生台灣繁體文字檔。"
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

    private func persistSettings() {
        do {
            try settingsRepository.save(settings)
        } catch {
            alert = UserFacingAlert(
                title: "無法儲存設定",
                message: error.localizedDescription
            )
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

    private func persistJobs() {
        for job in jobs where job.stage.isTerminal {
            let summary = RecentJobSummary(job: job)
            recentJobs.removeAll(where: { $0.id == summary.id })
            recentJobs.append(summary)
        }

        let limit = max(settings.recentJobLimit, 0)
        recentJobs = JobRetentionPolicy.recentSummaries(
            recentJobs,
            limit: limit
        )
        let ledgerJobs = JobRetentionPolicy.ledgerJobs(
            jobs,
            terminalHistoryLimit: limit
        )

        do {
            try recentJobsRepository.save(RecentJobCollection(jobs: recentJobs))
            try jobLedgerRepository.save(JobLedgerCollection(jobs: ledgerJobs))
        } catch {
            alert = UserFacingAlert(
                title: "無法儲存工作記錄",
                message: error.localizedDescription
            )
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

import RecordToTextCore
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var isDropTargeted = false
    @State private var isClearFinishedJobsPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                titleBlock
                terminologyCard
                intakeCard
                queueCard
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    viewModel.isGlossaryManagerPresented = true
                } label: {
                    Label("詞庫管理", systemImage: "text.book.closed")
                }
                .help("詞庫管理：編輯共用詞彙與專案詞庫，供轉錄 Prompt 使用")
                .accessibilityLabel("詞庫管理")
                .accessibilityHint("開啟詞庫管理視窗")

                Button {
                    viewModel.refreshEnvironment()
                    viewModel.isEnvironmentPresented = true
                } label: {
                    Label("環境檢查", systemImage: "checkmark.shield")
                }
                .help("環境檢查：確認 ffmpeg／ffprobe 是否就緒（Google AI Studio 使用 App 內建版本）")
                .accessibilityLabel("環境檢查")
                .accessibilityHint("開啟執行環境檢查")

                Button {
                    viewModel.refreshRecoveryScan()
                } label: {
                    Label("復原掃描", systemImage: "externaldrive.badge.timemachine")
                }
                .help("復原掃描：檢查系統暫存與 Temp-Recovery，可刪除殘留或重新加入來源音檔")
                .accessibilityLabel("復原掃描")
                .accessibilityHint("掃描並管理未清理的暫存與復原資料")

                SettingsLink {
                    Label("設定", systemImage: "gearshape")
                }
                .help("設定：輸出位置、檔名後綴、模型選擇、通知與 Developer Mode")
                .accessibilityLabel("設定")
                .accessibilityHint("開啟 App 設定")
            }
        }
        .sheet(isPresented: $viewModel.isPromptPreviewPresented) {
            PromptPreviewView(
                prompt: viewModel.promptPreview,
                termCount: viewModel.promptTermCount
            )
        }
        .sheet(isPresented: $viewModel.isGlossaryManagerPresented) {
            GlossaryManagerView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isEnvironmentPresented) {
            EnvironmentCheckView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isRecoveryScanPresented) {
            RecoveryScanView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isOnboardingPresented) {
            OnboardingView(viewModel: viewModel)
                .interactiveDismissDisabled()
        }
        .alert(item: $viewModel.alert) { item in
            Alert(
                title: Text(item.title),
                message: Text(item.message),
                dismissButton: .default(Text("好"))
            )
        }
        .confirmationDialog(
            "這些檔案已在佇列中",
            isPresented: $viewModel.isDuplicateConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("仍然加入") {
                viewModel.confirmDuplicateFiles()
            }
            Button("略過重複檔案", role: .cancel) {
                viewModel.discardDuplicateFiles()
            }
        } message: {
            Text("重複加入會各自產生一份工作與輸出檔。")
        }
        .confirmationDialog(
            "目前後端不支援專有名詞提示",
            isPresented: Binding(
                get: { viewModel.isPromptConsentPresented },
                set: { isPresented in
                    if !isPresented, viewModel.isPromptConsentPresented {
                        viewModel.declineRetryWithoutGlossaryPrompt()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("不用詞庫重試") {
                viewModel.retryWithoutGlossaryPrompt()
            }
            Button("保留失敗狀態", role: .cancel) {
                viewModel.declineRetryWithoutGlossaryPrompt()
            }
        } message: {
            Text("只有明確選擇後，record-to-text 才會在不套用專有名詞的情況下重試。")
        }
    }

    private var titleBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("record-to-text")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                Text(viewModel.appSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            quickModelMenu
        }
    }

    private var quickModelMenu: some View {
        Menu {
            ForEach(QuickTranscriptionChoice.allCases) { choice in
                Button {
                    viewModel.selectQuickTranscriptionChoice(choice)
                } label: {
                    Label(
                        choice.displayName,
                        systemImage: quickModelMenuIcon(for: choice)
                    )
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: viewModel.selectedModelIcon)
                Text(viewModel.selectedModelName)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .fixedSize()
        .help("快速切換轉錄模型；只影響之後加入的錄音")
        .accessibilityLabel("轉錄模型")
        .accessibilityValue(viewModel.selectedModelName)
        .accessibilityHint("點擊以切換 Qwen、Vertex AI 或 Google AI Studio")
    }

    private func quickModelMenuIcon(
        for choice: QuickTranscriptionChoice
    ) -> String {
        if viewModel.selectedQuickTranscriptionChoice == choice {
            return "checkmark"
        }
        return choice.backendType == .localQwen ? "apple.logo" : "cloud.fill"
    }

    private var terminologyCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Label("專有名詞", systemImage: "character.book.closed")
                        .font(.headline)
                    Spacer()
                    Text("\(viewModel.promptTermCount) 個詞彙")
                        .font(.caption.weight(.medium))
                        .foregroundColor(viewModel.promptErrorMessage == nil ? .secondary : .red)
                }

                HStack(spacing: 10) {
                    Picker(
                        "專案詞庫",
                        selection: Binding(
                            get: { viewModel.settings.lastSelectedGlossaryID },
                            set: { viewModel.selectGlossary($0) }
                        )
                    ) {
                        Text("不使用專案詞庫").tag(String?.none)
                        ForEach(viewModel.glossaryCollection.glossaries) { glossary in
                            Text(glossary.name).tag(Optional(glossary.id))
                        }
                    }
                    .frame(maxWidth: 330)

                    Button("管理詞庫…") {
                        viewModel.isGlossaryManagerPresented = true
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("本次補充")
                        .font(.subheadline.weight(.medium))

                    TextEditor(
                        text: Binding(
                            get: { viewModel.settings.lastTemporaryTerms },
                            set: { viewModel.setTemporaryTerms($0) }
                        )
                    )
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 84, maxHeight: 116)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                    .accessibilityLabel("本次補充專有名詞")

                    Text("可用逗號、頓號、分號、空格（中文詞彙）或換行分隔。加入檔案時會鎖定為該工作的 Snapshot。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = viewModel.promptErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Button {
                        viewModel.isPromptPreviewPresented = true
                    } label: {
                        Label("預覽實際送入模型的 Prompt", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private var intakeCard: some View {
        AppCard {
            VStack(spacing: 14) {
                DropZoneView(
                    isTargeted: isDropTargeted,
                    chooseFiles: { viewModel.chooseAudioFiles() }
                )
                // Finder supplies dropped files as `public.file-url` item
                // providers. Resolve that representation explicitly instead
                // of relying on SwiftUI's URL Transferable conversion, which
                // can return an empty URL array on macOS.
                .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleFileDrop(providers)
                }

                HStack(spacing: 10) {
                    Button {
                        viewModel.chooseAndMergeTranscriptFiles()
                    } label: {
                        Label("合併文字稿…", systemImage: "arrow.triangle.merge")
                    }
                    .buttonStyle(.bordered)
                    .help("選取兩份以上 TXT，依分段編號排序後合併成新檔")

                    Text("可直接選取切半後的多份 TXT；原檔不會被覆寫。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("輸出位置")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(viewModel.outputLocationSummary)
                            .font(.callout)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Text("等待手動開始")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if viewModel.hasQueuedJobs {
                    HStack(spacing: 10) {
                        Button {
                            viewModel.startQueuedJobs()
                        } label: {
                            Label("開始轉文字", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .help("開始處理佇列中等待的錄音（一次一個）")

                        splitQueuedAction
                    }
                }
            }
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else {
            return false
        }

        Task { @MainActor in
            let urls = await Self.fileURLs(from: providers)
            viewModel.addFiles(urls)
        }
        return true
    }

    private static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            guard let url = await fileURL(from: provider) else {
                continue
            }
            urls.append(url)
        }
        return urls
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, _ in
                continuation.resume(returning: parseDroppedFileURL(item))
            }
        }
    }

    private static func parseDroppedFileURL(_ item: NSSecureCoding?) -> URL? {
        if let url = item as? URL, url.isFileURL {
            return url
        }
        if let url = item as? NSURL, url.isFileURL {
            return url as URL
        }
        if let string = item as? String {
            return parseDroppedFileURLString(string)
        }
        if let data = item as? Data {
            return parseDroppedFileURLString(String(decoding: data, as: UTF8.self))
        }
        return nil
    }

    private static func parseDroppedFileURLString(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if let url = URL(string: trimmed), url.isFileURL {
            return url
        }
        let url = URL(fileURLWithPath: trimmed)
        return url.isFileURL ? url : nil
    }

    private var queueCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("工作佇列", systemImage: "list.bullet.rectangle")
                        .font(.headline)
                    Spacer()

                    if viewModel.hasQueuedJobs {
                        Button {
                            viewModel.startQueuedJobs()
                        } label: {
                            Label("開始轉文字", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("開始處理佇列中等待的錄音")

                        splitQueuedAction
                    }

                    if viewModel.hasActiveJob {
                        Button(role: .destructive) {
                            viewModel.cancelCurrentJob()
                        } label: {
                            Label("取消目前工作", systemImage: "stop.fill")
                        }
                    }

                    if viewModel.hasFinishedJobs {
                        Button(role: .destructive) {
                            isClearFinishedJobsPresented = true
                        } label: {
                            Label("刪除全部已結束", systemImage: "trash")
                        }
                        .help("刪除佇列與最近工作中所有已結束的工作（失敗／取消／完成等）")
                    }
                }

                if viewModel.jobs.isEmpty {
                    VStack(spacing: 9) {
                        Image(systemName: "waveform")
                            .font(.system(size: 26))
                            .foregroundStyle(.tertiary)
                        Text("尚未加入錄音")
                            .font(.subheadline.weight(.medium))
                        Text("加入多個檔案後會依序處理，同時間只執行一個工作。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.jobs) { job in
                            JobRowView(job: job, viewModel: viewModel)
                        }
                    }
                }

                if !archivedRecentJobs.isEmpty {
                    Divider()
                        .padding(.vertical, 2)

                    Text("最近工作")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    LazyVStack(spacing: 8) {
                        ForEach(archivedRecentJobs) { summary in
                            RecentJobRow(summary: summary, viewModel: viewModel)
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "刪除全部已結束的工作？",
            isPresented: $isClearFinishedJobsPresented,
            titleVisibility: .visible
        ) {
            Button("刪除全部已結束", role: .destructive) {
                viewModel.removeAllFinishedJobs()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("會從佇列與最近工作移除所有失敗、取消、中斷與已完成的項目。不會刪除原始錄音或已輸出的文字檔。進行中與排隊中的工作會保留。")
        }
    }

    private var archivedRecentJobs: [RecentJobSummary] {
        let liveIDs = Set(viewModel.jobs.map(\.id))
        return viewModel.recentJobs
            .filter { !liveIDs.contains($0.id) }
            .sorted {
                ($0.completedAt ?? $0.startedAt ?? .distantPast)
                    > ($1.completedAt ?? $1.startedAt ?? .distantPast)
            }
    }

    @ViewBuilder
    private var splitQueuedAction: some View {
        if let job = viewModel.splittableQueuedJobs.first,
           viewModel.splittableQueuedJobs.count == 1
        {
            Button {
                viewModel.splitQueuedAudioFileInHalf(job.id)
            } label: {
                Label("切分再依序轉", systemImage: "scissors")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("把已加入佇列的錄音切成前後兩段；第一段先處理，第二段排在後面")
        } else if viewModel.hasSplittableQueuedJobs {
            Menu {
                ForEach(viewModel.splittableQueuedJobs) { job in
                    Button {
                        viewModel.splitQueuedAudioFileInHalf(job.id)
                    } label: {
                        Label(job.displayName, systemImage: "scissors")
                    }
                }
            } label: {
                Label("切分再依序轉", systemImage: "scissors")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("選擇已加入佇列的錄音，切成前後兩段並依序處理")
        }
    }
}

private struct DropZoneView: View {
    let isTargeted: Bool
    let chooseFiles: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: isTargeted ? "arrow.down.doc.fill" : "waveform.badge.plus")
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)

            VStack(spacing: 4) {
                Text(isTargeted ? "放開以加入佇列" : "將錄音拖到這裡")
                    .font(.title3.weight(.semibold))
                Text("M4A、MP3、WAV、AAC、FLAC")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("選擇錄音檔…", action: chooseFiles)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

            Text("加入後可在「開始轉文字」旁切分，再依序處理。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            isTargeted ? Color.accentColor.opacity(0.09) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [7, 5])
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("錄音檔拖放區")
        .accessibilityHint("拖入支援的錄音檔，或按下按鈕選擇檔案")
    }
}

private struct JobRowView: View {
    let job: TranscriptionJob
    @ObservedObject var viewModel: AppViewModel
    @State private var isLogExpanded = false
    @State private var isDeleteRecoveryPresented = false
    @State private var isDeleteJobPresented = false

    var body: some View {
        rowContent
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
        }
        .contextMenu {
            if job.stage == .completed {
                Button("打開文字檔") {
                    viewModel.openOutput(for: job)
                }
                Button("在 Finder 顯示") {
                    viewModel.revealOutput(for: job)
                }
            }
            if job.stage == .failed || job.stage == .cancelled || job.stage == .interrupted {
                Button("用原工作設定重試") {
                    viewModel.retryJob(job.id)
                }
                Button("用目前設定建立新工作") {
                    viewModel.retryJob(job.id, usingCurrentSettings: true)
                }
            }
            if job.stage.isTerminal {
                Divider()
                Button("從列表刪除", role: .destructive) {
                    isDeleteJobPresented = true
                }
            }
        }
        .confirmationDialog(
            "刪除這筆工作的復原資料？",
            isPresented: $isDeleteRecoveryPresented,
            titleVisibility: .visible
        ) {
            Button("刪除復原資料", role: .destructive) {
                viewModel.deleteRecovery(for: job)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只會刪除 record-to-text 管理的復原資料，不會刪除原始錄音或文字稿。")
        }
        .confirmationDialog(
            "從列表刪除這筆工作？",
            isPresented: $isDeleteJobPresented,
            titleVisibility: .visible
        ) {
            Button("刪除", role: .destructive) {
                viewModel.removeFinishedJob(job.id)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只會從佇列／最近工作移除紀錄，不會刪除原始錄音或已輸出的文字檔。")
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            rowHeader
            progressSection
            cloudMetadataSection
            failureSection
            logSection
        }
    }

    private var rowHeader: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: statusSymbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 7) {
                    Text(job.stage.displayName)
                        .font(.caption)
                        .foregroundStyle(statusColor)

                    // Only show a live timer while the job is running.
                    // Completed jobs stay as plain「完成」with no counting clock.
                    if job.id == viewModel.activeJobID {
                        JobElapsedView(startedAt: job.startedAt)
                    }
                }
            }

            Spacer()
            actionButtons
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        if job.progressUnit?.hasPrefix("waiting") == true,
           job.id == viewModel.activeJobID {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text(waitingProgressLabel(job.progressUnit))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(waitingProgressLabel(job.progressUnit))
        } else if let current = job.progressCurrent,
                  let total = job.progressTotal,
                  total > 0 {
            ProgressView(value: min(current, total), total: total) {
                Text(progressLabel(current: current, total: total, unit: job.progressUnit))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .animation(.easeInOut(duration: 0.2), value: current)
        } else if job.id == viewModel.activeJobID {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(job.stage.displayName)
        }
    }

    private func waitingProgressLabel(_ unit: String?) -> String {
        let parts = (unit ?? "").split(separator: "|")
        if parts.count == 3 {
            return "等待 Gemini 回應 · 第 \(parts[1])／\(parts[2]) 段（無虛構百分比）"
        }
        return "等待 Gemini 回應（無虛構百分比）"
    }

    @ViewBuilder
    private var cloudMetadataSection: some View {
        if job.snapshot.backendType != .localQwen {
            let metadata = job.resolvedCloudSegmentMetadata
            VStack(alignment: .leading, spacing: 3) {
                Text(job.cloudModelSummary ?? job.snapshot.requestedModelID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !metadata.isEmpty {
                    let usage = CloudTranscriptionMetadataAggregator
                        .totalUsage(metadata)
                    let retries = CloudTranscriptionMetadataAggregator
                        .totalRetryCount(metadata)
                    HStack(spacing: 8) {
                        if let total = usage?.totalTokenCount {
                            Text("總 token \(total)")
                        }
                        if let thoughts = usage?.thoughtsTokenCount {
                            Text("thinking \(thoughts)")
                        }
                        if retries > 0 {
                            Text("重試 \(retries)")
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var failureSection: some View {
        if let failure = job.failure {
            VStack(alignment: .leading, spacing: 5) {
                Text(failure.userMessage)
                    .font(.caption)
                    .foregroundStyle(job.stage == .cancelled ? Color.secondary : Color.red)
                if failure.recoveryDirectory != nil {
                    HStack(spacing: 12) {
                        if failure.partialTranscriptPath != nil {
                            Button("打開未完成稿") {
                                viewModel.openPartialTranscript(for: job)
                            }
                        }

                        if viewModel.canResumeCloudJob(job) {
                            Button("從已完成片段續跑") {
                                viewModel.resumeCloudJobFromCheckpoint(job.id)
                            }
                            .buttonStyle(.link)
                        } else if viewModel.canResumeLocalQwenJob(job) {
                            Button("從已完成 Qwen chunk 續跑") {
                                viewModel.resumeLocalQwenJobFromCheckpoint(job.id)
                            }
                            .buttonStyle(.link)
                        }

                        Button("在 Finder 顯示復原資料") {
                            viewModel.revealRecovery(for: job)
                        }
                        .buttonStyle(.link)

                        Button("刪除保留資料…", role: .destructive) {
                            isDeleteRecoveryPresented = true
                        }
                        .buttonStyle(.link)
                    }
                    .font(.caption)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (job.stage == .cancelled ? Color.orange : Color.red)
                    .opacity(0.07),
                in: RoundedRectangle(cornerRadius: 7)
            )
        }
    }

    @ViewBuilder
    private var logSection: some View {
        if !job.logLines.isEmpty {
            DisclosureGroup("執行日誌", isExpanded: $isLogExpanded) {
                ScrollView {
                    Text(job.logLines.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 150)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if job.id == viewModel.activeJobID {
            Button {
                viewModel.cancelCurrentJob()
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("取消目前工作")
        } else if job.stage == .queued {
            Button {
                viewModel.removeQueuedJob(job.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("從佇列移除")
        } else if job.stage == .completed {
            Button {
                viewModel.revealOutput(for: job)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("在 Finder 顯示")

            Button {
                viewModel.openOutput(for: job)
            } label: {
                Image(systemName: "doc.text")
            }
            .buttonStyle(.borderless)
            .help("打開文字檔")

            Button(role: .destructive) {
                isDeleteJobPresented = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("從列表刪除這筆工作")
        } else if job.stage == .failed || job.stage == .cancelled || job.stage == .interrupted {
            Button {
                viewModel.retryJob(job.id)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("沿用原工作設定重試")

            Button(role: .destructive) {
                isDeleteJobPresented = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("從列表刪除這筆工作")
        }
    }

    private func progressLabel(current: Double, total: Double, unit: String?) -> String {
        let rawUnit = unit ?? ""
        if rawUnit == "percent" || rawUnit.hasPrefix("percent|") {
            let percent = Int(min(max(current, 0), total).rounded())
            let parts = rawUnit.split(separator: "|", omittingEmptySubsequences: false)
            if parts.count == 3, let segment = Int(parts[1]), let count = Int(parts[2]) {
                return "整體 \(percent)% · 第 \(segment)／\(count) 段"
            }
            return "整體 \(percent)%"
        }
        if rawUnit == "segments" {
            return "第 \(Int(current.rounded()))／\(Int(total.rounded())) 段"
        }
        if rawUnit.isEmpty {
            return "\(Int(current.rounded())) / \(Int(total.rounded()))"
        }
        return "\(Int(current.rounded())) / \(Int(total.rounded())) \(rawUnit)"
    }

    private var statusSymbol: String {
        switch job.stage {
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.circle.fill"
        case .cancelled, .interrupted:
            return "minus.circle.fill"
        case .queued:
            return "clock"
        default:
            return "waveform.circle.fill"
        }
    }

    private var statusColor: Color {
        switch job.stage {
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled, .interrupted:
            return .secondary
        case .queued:
            return .secondary
        default:
            return .accentColor
        }
    }
}

private struct JobElapsedView: View {
    let startedAt: Date?

    var body: some View {
        if let startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.formatter.string(from: max(context.date.timeIntervalSince(startedAt), 0)) ?? "")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let formatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()
}

private struct RecentJobRow: View {
    let summary: RecentJobSummary
    @ObservedObject var viewModel: AppViewModel
    @State private var isDeletePresented = false
    // Filesystem stats are captured once per row (and when the summary
    // changes) instead of on every render of every row.
    @State private var fileStatus: RecentJobFileStatus = .available
    @State private var sourceIsAvailable = false
    @State private var outputIsAvailable = false

    var body: some View {
        statusList
        .onAppear(perform: refreshAvailability)
        .onChange(of: summary) { refreshAvailability() }
    }

    private var statusList: some View {
        HStack(spacing: 11) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(summary.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 7) {
                    Text(summary.stage.displayName)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                    if let fileStatusName = fileStatus.displayName {
                        Text("・\(fileStatusName)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let glossaryName = summary.glossaryName {
                        Text("・\(glossaryName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let cloudModel = summary.cloudModelSummary {
                        Text("・\(cloudModel)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            if outputIsAvailable {
                Button {
                    viewModel.revealOutput(for: summary)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("在 Finder 顯示")

                Button {
                    viewModel.openOutput(for: summary)
                } label: {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.borderless)
                .help("打開文字檔")
            }

            if sourceIsAvailable {
                Button {
                    viewModel.retryRecentJob(summary)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("用目前設定建立新工作")
            }

            Button(role: .destructive) {
                isDeletePresented = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("從列表刪除這筆工作")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .confirmationDialog(
            "從列表刪除這筆工作？",
            isPresented: $isDeletePresented,
            titleVisibility: .visible
        ) {
            Button("刪除", role: .destructive) {
                viewModel.removeFinishedJob(summary.id)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只會從最近工作移除紀錄，不會刪除原始錄音或已輸出的文字檔。")
        }
        .contextMenu {
            if outputIsAvailable {
                Button("打開文字檔") {
                    viewModel.openOutput(for: summary)
                }
                Button("在 Finder 顯示") {
                    viewModel.revealOutput(for: summary)
                }
            }
            if sourceIsAvailable {
                Button("用目前設定建立新工作") {
                    viewModel.retryRecentJob(summary)
                }
            }
            Divider()
            Button("從列表刪除", role: .destructive) {
                isDeletePresented = true
            }
        }
    }

    private func refreshAvailability() {
        fileStatus = summary.fileStatus()
        sourceIsAvailable = FileManager.default.fileExists(atPath: summary.sourcePath)
        if summary.stage == .completed, let outputPath = summary.outputPath {
            outputIsAvailable = FileManager.default.fileExists(atPath: outputPath)
        } else {
            outputIsAvailable = false
        }
    }

    private var statusSymbol: String {
        if fileStatus != .available {
            return "exclamationmark.triangle.fill"
        }
        switch summary.stage {
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.circle.fill"
        case .cancelled, .interrupted:
            return "minus.circle.fill"
        default:
            return "clock"
        }
    }

    private var statusColor: Color {
        if fileStatus != .available {
            return .orange
        }
        switch summary.stage {
        case .completed:
            return .green
        case .failed:
            return .red
        default:
            return .secondary
        }
    }
}

private struct PromptPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let prompt: String
    let termCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt 預覽")
                        .font(.title2.weight(.semibold))
                    Text("這段內容會隨工作 Snapshot 鎖定，共 \(termCount) 個詞彙。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                Text(prompt)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
        .padding(22)
        .frame(width: 640, height: 480)
    }
}

struct AppCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            }
    }
}

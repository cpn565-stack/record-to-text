import RecordToTextCore
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var isDropTargeted = false

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
                .help("管理共用詞彙與專案詞庫")

                Button {
                    viewModel.refreshEnvironment()
                    viewModel.isEnvironmentPresented = true
                } label: {
                    Label("環境檢查", systemImage: "checkmark.shield")
                }
                .help("檢查 Runtime 與轉錄工具")

                SettingsLink {
                    Label("設定", systemImage: "gearshape")
                }
                .help("開啟設定")
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
                Text("把會議錄音留在這台 Mac，產生可繼續整理的台灣繁體文字稿。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(
                viewModel.selectedModelName,
                systemImage: CPUArchitecture.current == .x86_64
                    ? "cpu"
                    : "apple.logo"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
        }
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

                    Text("可用逗號、頓號、分號或換行分隔。加入檔案時會鎖定為該工作的 Snapshot。")
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
                DropZoneView(isTargeted: isDropTargeted) {
                    viewModel.chooseAudioFiles()
                }
                .dropDestination(for: URL.self) { urls, _ in
                    viewModel.addFiles(urls)
                    return !urls.isEmpty
                } isTargeted: { targeted in
                    withAnimation(.easeOut(duration: 0.15)) {
                        isDropTargeted = targeted
                    }
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
                    Text(viewModel.settings.autoStartAfterSelection ? "加入後自動開始" : "等待手動開始")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var queueCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("工作佇列", systemImage: "list.bullet.rectangle")
                        .font(.headline)
                    Spacer()

                    if !viewModel.settings.autoStartAfterSelection, viewModel.hasQueuedJobs {
                        Button {
                            viewModel.startQueuedJobs()
                        } label: {
                            Label("開始", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if viewModel.hasActiveJob {
                        Button(role: .destructive) {
                            viewModel.cancelCurrentJob()
                        } label: {
                            Label("取消目前工作", systemImage: "stop.fill")
                        }
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

            Button("選擇錄音檔…", action: chooseFiles)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            if let current = job.progressCurrent,
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

            if let failure = job.failure {
                VStack(alignment: .leading, spacing: 5) {
                    Text(failure.userMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                    if failure.recoveryDirectory != nil {
                        HStack(spacing: 12) {
                            Button("在 Finder 顯示保留的 WAV") {
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
                .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            }

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
        }
        .confirmationDialog(
            "刪除這筆工作的復原資料？",
            isPresented: $isDeleteRecoveryPresented,
            titleVisibility: .visible
        ) {
            Button("刪除保留的 WAV", role: .destructive) {
                viewModel.deleteRecovery(for: job)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只會刪除 record-to-text 管理的復原資料，不會刪除原始錄音或文字稿。")
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
        } else if job.stage == .failed || job.stage == .cancelled || job.stage == .interrupted {
            Button {
                viewModel.retryJob(job.id)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("沿用原工作設定重試")
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

    var body: some View {
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
                    if let glossaryName = summary.glossaryName {
                        Text("・\(glossaryName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if summary.stage == .completed, summary.outputPath != nil {
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

            Button {
                viewModel.retryRecentJob(summary)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("用目前設定建立新工作")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .contextMenu {
            if summary.stage == .completed, summary.outputPath != nil {
                Button("打開文字檔") {
                    viewModel.openOutput(for: summary)
                }
                Button("在 Finder 顯示") {
                    viewModel.revealOutput(for: summary)
                }
            }
            Button("用目前設定建立新工作") {
                viewModel.retryRecentJob(summary)
            }
        }
    }

    private var statusSymbol: String {
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

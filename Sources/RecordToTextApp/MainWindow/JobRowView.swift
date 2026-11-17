import RecordToTextCore
import SwiftUI

struct JobRowView: View {
    let job: TranscriptionJob
    @ObservedObject var viewModel: AppViewModel
    @Binding var isLogExpanded: Bool
    var isPrimaryCompleted: Bool = false
    var isCompletionHighlighted: Bool = false
    var onQuickLook: ((URL) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var isDeleteRecoveryPresented = false
    @State private var isDeleteJobPresented = false
    @State private var isPromptPresented = false

    // Cached disk/checkpoint checks — never query FileManager inside `body`.
    @State private var fileStatus: RecentJobFileStatus = .available
    @State private var sourceIsAvailable = false
    @State private var outputIsAvailable = false
    @State private var cloudResumeIsAvailable = false
    @State private var localQwenResumeIsAvailable = false

    private var isRunningJob: Bool {
        job.id == viewModel.activeJobID || (!job.stage.isTerminal && job.stage != .queued)
    }

    private var hasLogsOrDiagnostics: Bool {
        !job.logLines.isEmpty || job.cloudDiagnostics != nil
    }

    var body: some View {
        rowContent
            .padding(AppSpacing.md)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: AppRadius.row))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.row)
                    .stroke(rowBorderColor, lineWidth: isCompletionHighlighted ? 1.5 : 1)
            }
            .overlay(alignment: .leading) {
                if isRunningJob {
                    Capsule()
                        .fill(AppColors.accent)
                        .frame(width: 3)
                        .padding(.vertical, 10)
                        .padding(.leading, 2)
                        .allowsHitTesting(false)
                }
            }
            .contextMenu {
                contextMenuItems
            }
            .sheet(isPresented: $isPromptPresented) {
                PromptPreviewView(
                    prompt: viewModel.promptPreview(for: job.snapshot),
                    termCount: job.snapshot.terms.count,
                    isJobSnapshot: true
                )
                .tint(AppColors.accent)
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

    private var rowBackground: Color {
        if isCompletionHighlighted {
            return AppColors.success.opacity(0.08)
        }
        if isRunningJob {
            return AppColors.accent.opacity(AppColors.activeRowTintOpacity)
        }
        return AppColors.cardBackground
    }

    private var rowBorderColor: Color {
        if isCompletionHighlighted {
            return AppColors.success.opacity(0.60)
        }
        return AppColors.hairlineBorder(colorSchemeContrast: contrast)
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            headerRow

            if isRunningJob {
                ActiveJobProgressView(job: job, viewModel: viewModel)
            }

            if job.stage == .completed {
                completedOutputLine
                completedWarningsCallout
            } else if job.stage.isTerminal || job.isCloudRecoveryPaused {
                terminalFailureOrRecoveryCallout
            }

            logAndDiagnosticsSection
        }
        .onAppear(perform: refreshCachedState)
        .onChange(of: job.stage) { _, _ in refreshCachedState() }
        .onChange(of: job.outputPath) { _, _ in refreshCachedState() }
        .onChange(of: job.failure) { _, _ in refreshCachedState() }
        .task(id: job.failure) {
            guard job.snapshot.backendType != .localQwen else {
                cloudResumeIsAvailable = false
                return
            }
            let available = await viewModel.cloudResumeAvailability(job)
            guard !Task.isCancelled else { return }
            cloudResumeIsAvailable = available
        }
    }

    // MARK: - Header & Metadata

    private var headerRow: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            statusIconView
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.displayName)
                    .font(AppTypography.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)

                metadataLine
            }

            Spacer(minLength: AppSpacing.sm)

            HStack(spacing: AppSpacing.sm) {
                if job.id == viewModel.activeJobID {
                    JobElapsedView(startedAt: job.startedAt)
                }
                actionButtons
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private var statusIconView: some View {
        let base = Image(systemName: statusSymbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(statusColor)

        if isRunningJob && statusSymbol == "waveform.circle.fill" {
            base.symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
        } else {
            base
        }
    }

    @ViewBuilder
    private var metadataLine: some View {
        let backendAndModel = JobModelDisplayHelper.displayBackendAndModel(for: job)
        let fallbackHelp = JobModelDisplayHelper.fallbackTooltip(for: job)

        if job.stage == .queued {
            Text(queuedMetadataString(backendAndModel: backendAndModel))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else if isRunningJob {
            Text(runningMetadataString(backendAndModel: backendAndModel))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(fallbackHelp ?? "")
        } else if job.stage == .completed {
            HStack(spacing: 0) {
                Text(job.statusWithCompletionTime())
                    .foregroundStyle(statusColor)
                    .fontWeight(.medium)
                Text(completedTrailingMetadata(backendAndModel: backendAndModel))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .lineLimit(2)
            .help(fallbackHelp ?? "")
        } else {
            HStack(spacing: 0) {
                Text(terminalStatusLabel)
                    .foregroundStyle(statusColor)
                    .fontWeight(.medium)
                Text(nonCompletedTrailingMetadata(backendAndModel: backendAndModel))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .lineLimit(2)
            .help(fallbackHelp ?? "")
        }
    }

    private func queuedMetadataString(backendAndModel: String) -> String {
        var parts = ["等待中", backendAndModel]
        if let glossary = job.snapshot.glossaryName, !glossary.isEmpty {
            parts.append("詞庫：\(glossary)")
        }
        if job.resumeFromRecoveryDirectory != nil {
            parts.append("檢查點續跑")
        }
        return parts.joined(separator: " · ")
    }

    private func runningMetadataString(backendAndModel: String) -> String {
        var parts = [backendAndModel]
        if let seg = CloudSegmentProgressState(unit: job.progressUnit) {
            parts.append("第 \(seg.currentSegment)／\(seg.totalSegments) 段")
        }
        if let glossary = job.snapshot.glossaryName, !glossary.isEmpty {
            parts.append("詞庫：\(glossary)")
        }
        if job.resumeFromRecoveryDirectory != nil {
            parts.append("檢查點續跑")
        }
        return parts.joined(separator: " · ")
    }

    private func completedTrailingMetadata(backendAndModel: String) -> String {
        var parts: [String] = []
        if let duration = JobModelDisplayHelper.formattedDuration(
            startedAt: job.startedAt,
            completedAt: job.completedAt
        ) {
            parts.append("耗時 \(duration)")
        }
        parts.append(backendAndModel)
        if let tokens = job.cloudTokenSummary {
            parts.append(tokens)
        }
        if let glossary = job.snapshot.glossaryName, !glossary.isEmpty {
            parts.append("詞庫：\(glossary)")
        }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }

    private func nonCompletedTrailingMetadata(backendAndModel: String) -> String {
        var parts = [backendAndModel]
        if let tokens = job.cloudTokenSummary {
            parts.append(tokens)
        }
        if let glossary = job.snapshot.glossaryName, !glossary.isEmpty {
            parts.append("詞庫：\(glossary)")
        }
        return " · " + parts.joined(separator: " · ")
    }

    private var terminalStatusLabel: String {
        if job.serviceRecovery?.state == .paused {
            return "Google 忙碌，已暫停"
        }
        if job.networkRecovery?.state == .paused {
            return "網路恢復逾限，已暫停"
        }
        return job.statusWithCompletionTime()
    }

    // MARK: - Completed Output & Warning Callouts

    @ViewBuilder
    private var completedOutputLine: some View {
        if let outputPath = job.outputPath {
            let outputName = URL(fileURLWithPath: outputPath).lastPathComponent
            HStack(spacing: 5) {
                Image(systemName: "doc.text")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if outputIsAvailable {
                    Button {
                        viewModel.openOutput(for: job)
                    } label: {
                        Text("輸出：\(outputName)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(outputPath)
                } else {
                    Text("輸出：\(outputName)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.leading, 34)
        }
    }

    @ViewBuilder
    private var completedWarningsCallout: some View {
        let gapMessage = job.failure?.userMessage
        let timestampNotice = job.cloudDiagnostics?.timestampNotice
        let missingFileNotice = fileStatus.displayName
        let hasWarnings = gapMessage != nil || timestampNotice != nil || missingFileNotice != nil

        if hasWarnings {
            InlineCallout(color: AppColors.warning) {
                VStack(alignment: .leading, spacing: 6) {
                    if let missingFileNotice {
                        Label(missingFileNotice, systemImage: "folder.badge.questionmark")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppColors.warning)
                    }
                    if let gapMessage {
                        Label(gapMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(AppColors.warning)
                    }
                    if let timestampNotice {
                        Label(timestampNotice, systemImage: "clock.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(AppColors.warning)
                    }
                    if job.failure?.recoveryDirectory != nil {
                        recoveryArtifactButtons
                    }
                }
            }
        }
    }

    // MARK: - Failed / Cancelled / Interrupted Callouts

    @ViewBuilder
    private var terminalFailureOrRecoveryCallout: some View {
        let hasResultUnknown = job.networkRecovery?.resultUnknown == true
            || job.serviceRecovery?.resultUnknown == true

        if job.failure != nil || hasResultUnknown {
            let calloutColor = job.stage == .failed ? AppColors.danger : AppColors.warning
            InlineCallout(color: calloutColor) {
                VStack(alignment: .leading, spacing: 6) {
                    if let failure = job.failure {
                        Text(failure.userMessage)
                            .font(.caption)
                            .foregroundStyle(job.stage == .failed ? AppColors.danger : .primary)
                    }
                    if hasResultUnknown {
                        Text("先前請求結果未知，重送未完成片段可能再次計費。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if job.failure?.recoveryDirectory != nil {
                        recoveryArtifactButtons
                    }
                }
            }
        }
    }

    private var recoveryArtifactButtons: some View {
        FlowLayout(horizontalSpacing: AppSpacing.sm, verticalSpacing: 6) {
            if job.failure?.partialTranscriptPath != nil {
                Button("打開未完成稿") {
                    viewModel.openPartialTranscript(for: job)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if localQwenResumeIsAvailable {
                Button("從已完成 Qwen chunk 續跑") {
                    viewModel.resumeLocalQwenJobFromCheckpoint(job.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button("在 Finder 顯示復原資料") {
                viewModel.revealRecovery(for: job)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("刪除保留資料…", role: .destructive) {
                isDeleteRecoveryPresented = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Logs & Diagnostics

    @ViewBuilder
    private var logAndDiagnosticsSection: some View {
        if hasLogsOrDiagnostics {
            if job.stage == .completed {
                // Completed rows omit noisy summary text unless explicitly expanded via `⋯`.
                if isLogExpanded {
                    VStack(alignment: .leading, spacing: 6) {
                        logHeaderControls
                        expandedDebugPanel
                    }
                }
            } else if job.stage != .queued || isLogExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if isRunningJob, let status = JobDebugClipboard.statusSummary(from: job.logLines) {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }

                    logHeaderControls

                    if isLogExpanded {
                        expandedDebugPanel
                    }
                }
            }
        }
    }

    private var logHeaderControls: some View {
        HStack(spacing: AppSpacing.md) {
            Button {
                toggleLogExpansion()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isLogExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                    Text(
                        JobDebugClipboard.logToggleTitle(
                            isExpanded: isLogExpanded,
                            lineCount: job.logLines.count,
                            hasDiagnostics: job.cloudDiagnostics != nil
                        )
                    )
                }
            }
            .buttonStyle(.link)
            .font(.caption)
            .help(isLogExpanded ? "收合執行日誌與分段診斷" : "在畫面上展開查看完整執行日誌與分段診斷")
            .accessibilityLabel(isLogExpanded ? "收合日誌" : "展開日誌")

            Button("複製除錯資訊") {
                JobDebugClipboard.copy(job)
            }
            .buttonStyle(.link)
            .font(.caption)
            .help("複製完整執行日誌、模型與失敗訊息，方便貼給除錯用")
        }
    }

    private var expandedDebugPanel: some View {
        let isDev = viewModel.settings.developerMode
        return ExpandableDebugTextPanel(
            text: JobDebugClipboard.expandedContent(for: job),
            showJumpToLatest: job.logLines.count > 4,
            developerJobID: isDev ? job.id : nil,
            developerBadges: isDev ? JobDebugClipboard.developerBadges(for: job) : []
        )
        .padding(.top, 2)
    }

    private func toggleLogExpansion() {
        if reduceMotion {
            isLogExpanded.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.15)) {
                isLogExpanded.toggle()
            }
        }
    }

    // MARK: - Explicit Action Buttons & Overflow Menu

    @ViewBuilder
    private var actionButtons: some View {
        if job.id == viewModel.activeJobID {
            Button {
                viewModel.cancelCurrentJob()
            } label: {
                Image(systemName: "stop.fill")
                    .foregroundStyle(AppColors.danger)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("取消目前工作（⌘.）")
            .accessibilityLabel("取消目前工作")
        } else if job.stage == .queued {
            if job.sourceSlice == nil {
                Menu {
                    Button {
                        viewModel.splitQueuedAudioFileInHalf(job.id)
                    } label: {
                        Label("切分再依序轉", systemImage: "scissors")
                    }
                    Button {
                        isPromptPresented = true
                    } label: {
                        Label("檢視轉錄提示", systemImage: "doc.text.magnifyingglass")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
                .help("更多佇列操作")
            }

            Button {
                viewModel.removeQueuedJob(job.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("從佇列移除")
            .accessibilityLabel("從佇列移除")
        } else if job.stage == .completed {
            TranscriptQuickLookButton(
                outputPath: job.outputPath,
                isOutputAvailable: outputIsAvailable
            ) { url in
                onQuickLook?(url)
            }

            if isPrimaryCompleted && outputIsAvailable {
                Button("打開文字檔") {
                    viewModel.openOutput(for: job)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button("打開文字檔") {
                    viewModel.openOutput(for: job)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!outputIsAvailable)
            }

            if job.hasPendingGapRecovery && job.snapshot.backendType != .localQwen {
                let resendStatus = viewModel.cloudResendStatus(job.id)
                Button(resendStatus ?? (cloudResumeIsAvailable ? "重送未完成片段" : "重新送出")) {
                    viewModel.resendCloudJob(job.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(resendStatus != nil)
            }

            completedOverflowMenu
        } else if job.stage == .failed || job.stage == .cancelled || job.stage == .interrupted {
            terminalPrimaryRetryButton

            if job.isCloudRecoveryPaused {
                Button("取消工作") {
                    viewModel.cancelNetworkPausedJob(job.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            terminalOverflowMenu
        }
    }

    @ViewBuilder
    private var terminalPrimaryRetryButton: some View {
        if job.snapshot.backendType != .localQwen {
            let resendStatus = viewModel.cloudResendStatus(job.id)
            Button {
                viewModel.resendCloudJob(job.id)
            } label: {
                Label(
                    resendStatus ?? (cloudResumeIsAvailable ? "重送未完成片段" : "重試"),
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(resendStatus != nil)
        } else if localQwenResumeIsAvailable {
            Button {
                viewModel.resumeLocalQwenJobFromCheckpoint(job.id)
            } label: {
                Label("從檢查點續跑", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Button {
                viewModel.retryJob(job.id)
            } label: {
                Label("重試", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var completedOverflowMenu: some View {
        Menu {
            if outputIsAvailable {
                Button {
                    viewModel.revealOutput(for: job)
                } label: {
                    Label("在 Finder 顯示", systemImage: "folder")
                }
            }

            if hasLogsOrDiagnostics {
                Button {
                    toggleLogExpansion()
                } label: {
                    Label(
                        isLogExpanded ? "收合日誌／診斷" : "展開日誌／診斷",
                        systemImage: "text.alignleft"
                    )
                }

                Button {
                    JobDebugClipboard.copy(job)
                } label: {
                    Label("複製除錯資訊", systemImage: "doc.on.doc")
                }
            }

            Button {
                isPromptPresented = true
            } label: {
                Label("檢視轉錄提示", systemImage: "doc.text.magnifyingglass")
            }

            if sourceIsAvailable {
                Button {
                    viewModel.retryJob(job.id, usingCurrentSettings: true)
                } label: {
                    Label("用目前設定建立新工作", systemImage: "plus.circle")
                }
            }

            Divider()

            Button(role: .destructive) {
                isDeleteJobPresented = true
            } label: {
                Label("從列表刪除", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
        .help("更多操作")
        .accessibilityLabel("更多操作")
    }

    private var terminalOverflowMenu: some View {
        Menu {
            if job.snapshot.backendType == .localQwen && localQwenResumeIsAvailable {
                Button {
                    viewModel.retryJob(job.id)
                } label: {
                    Label("用原工作設定從頭重試", systemImage: "arrow.clockwise")
                }
            }

            if sourceIsAvailable {
                Button {
                    viewModel.retryJob(job.id, usingCurrentSettings: true)
                } label: {
                    Label("用目前設定建立新工作", systemImage: "plus.circle")
                }
            }

            Button {
                isPromptPresented = true
            } label: {
                Label("檢視轉錄提示", systemImage: "doc.text.magnifyingglass")
            }

            if hasLogsOrDiagnostics {
                Button {
                    toggleLogExpansion()
                } label: {
                    Label(
                        isLogExpanded ? "收合日誌／診斷" : "展開日誌／診斷",
                        systemImage: "text.alignleft"
                    )
                }

                Button {
                    JobDebugClipboard.copy(job)
                } label: {
                    Label("複製除錯資訊", systemImage: "doc.on.doc")
                }
            }

            Divider()

            Button(role: .destructive) {
                isDeleteJobPresented = true
            } label: {
                Label("從列表刪除", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
        .help("更多操作")
        .accessibilityLabel("更多操作")
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("檢視轉錄提示") {
            isPromptPresented = true
        }
        if job.stage == .completed {
            if let outputPath = job.outputPath, outputIsAvailable {
                Button("快速預覽（Quick Look）") {
                    onQuickLook?(URL(fileURLWithPath: outputPath))
                }
                Button("打開文字檔") {
                    viewModel.openOutput(for: job)
                }
                Button("在 Finder 顯示") {
                    viewModel.revealOutput(for: job)
                }
            }
            if sourceIsAvailable {
                Button("用目前設定建立新工作") {
                    viewModel.retryJob(job.id, usingCurrentSettings: true)
                }
            }
        }
        if job.stage == .failed || job.stage == .cancelled || job.stage == .interrupted {
            Button("用原工作設定重試") {
                viewModel.retryJob(job.id)
            }
            if sourceIsAvailable {
                Button("用目前設定建立新工作") {
                    viewModel.retryJob(job.id, usingCurrentSettings: true)
                }
            }
        }
        if hasLogsOrDiagnostics {
            Button(isLogExpanded ? "收合日誌／診斷" : "展開日誌／診斷") {
                toggleLogExpansion()
            }
            Button("複製除錯資訊") {
                JobDebugClipboard.copy(job)
            }
        }
        if job.stage.isTerminal {
            Divider()
            Button("從列表刪除", role: .destructive) {
                isDeleteJobPresented = true
            }
        }
    }

    // MARK: - Cached State & Status Styling

    private func refreshCachedState() {
        let sourceExists = FileManager.default.fileExists(atPath: job.sourcePath)
        sourceIsAvailable = sourceExists
        if job.stage == .completed {
            let outExists = job.outputPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
            outputIsAvailable = outExists
            switch (sourceExists, outExists) {
            case (false, false):
                fileStatus = .sourceAndOutputMissing
            case (false, true):
                fileStatus = .sourceMissing
            case (true, false):
                fileStatus = .outputMissing
            case (true, true):
                fileStatus = .available
            }
        } else {
            outputIsAvailable = false
            fileStatus = .available
        }
        localQwenResumeIsAvailable = viewModel.canResumeLocalQwenJob(job)
    }

    private var statusSymbol: String {
        if isRunningJob {
            if job.serviceRecovery?.state == .coolingDown || job.networkRecovery?.state == .waiting {
                return "pause.circle.fill"
            }
            if job.serviceRecovery?.state == .retrying || job.networkRecovery?.state == .retrying {
                return "arrow.clockwise.circle.fill"
            }
            return "waveform.circle.fill"
        }
        if job.isCloudRecoveryPaused {
            return "pause.circle.fill"
        }
        if job.stage == .completed {
            if fileStatus == .outputMissing || fileStatus == .sourceAndOutputMissing {
                return "folder.badge.questionmark"
            }
            if job.resolvedOutputCompleteness == .hasGaps {
                return "exclamationmark.triangle.fill"
            }
            return "checkmark.circle.fill"
        }
        switch job.stage {
        case .queued:
            return "clock"
        case .failed:
            return "exclamationmark.circle.fill"
        case .interrupted:
            return "arrow.clockwise.circle.fill"
        case .cancelled:
            return "minus.circle.fill"
        default:
            return "waveform.circle.fill"
        }
    }

    private var statusColor: Color {
        if isRunningJob {
            if job.serviceRecovery?.state == .coolingDown
                || job.serviceRecovery?.state == .retrying
                || job.networkRecovery?.state == .waiting
                || job.networkRecovery?.state == .retrying
            {
                return AppColors.warning
            }
            return AppColors.accent
        }
        if job.isCloudRecoveryPaused {
            return AppColors.warning
        }
        if job.stage == .completed {
            if fileStatus != .available || job.resolvedOutputCompleteness == .hasGaps {
                return AppColors.warning
            }
            return AppColors.success
        }
        switch job.stage {
        case .queued, .cancelled:
            return AppColors.neutral
        case .failed:
            return AppColors.danger
        case .interrupted:
            return AppColors.warning
        default:
            return AppColors.accent
        }
    }
}

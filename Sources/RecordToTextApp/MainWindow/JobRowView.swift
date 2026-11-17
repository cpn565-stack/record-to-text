import RecordToTextCore
import SwiftUI

struct JobRowView: View {
    let job: TranscriptionJob
    @ObservedObject var viewModel: AppViewModel
    @Binding var isLogExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDeleteRecoveryPresented = false
    @State private var isDeleteJobPresented = false
    @State private var trackedSegment: Int?
    @State private var currentSegmentStartedAt = Date()
    @State private var cloudResumeIsAvailable = false
    @State private var isPromptPresented = false

    var body: some View {
        rowContent
        .padding(12)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    Color(nsColor: .separatorColor).opacity(0.48),
                    lineWidth: 1
                )
        }
        .overlay(alignment: .leading) {
            if isActiveJob {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 10)
                    .padding(.leading, 2)
                    .allowsHitTesting(false)
            }
        }
        .contextMenu {
            Button("檢視轉錄提示") { isPromptPresented = true }
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
            if !job.logLines.isEmpty || job.cloudDiagnostics != nil {
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
        .sheet(isPresented: $isPromptPresented) {
            PromptPreviewView(prompt: viewModel.promptPreview(for: job.snapshot),
                termCount: job.snapshot.terms.count, isJobSnapshot: true)
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

    private var isActiveJob: Bool {
        job.id == viewModel.activeJobID
    }

    @ViewBuilder
    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            rowHeader
            progressSection
            failureSection
            if let notice = job.cloudDiagnostics?.timestampNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            logSection
        }
        .onAppear(perform: rememberCurrentSegment)
        .task(id: job.failure) {
            let available = await viewModel.cloudResumeAvailability(job)
            guard !Task.isCancelled else { return }
            cloudResumeIsAvailable = available
        }
        .onChange(of: job.progressUnit) { _, _ in
            rememberCurrentSegment()
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

                Text(job.snapshot.engineDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if job.resumeFromRecoveryDirectory != nil {
                    Text("檢查點續跑：沿用原後端與模型")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                HStack(spacing: 7) {
                    Text(job.serviceRecovery?.state == .paused ? "Google 忙碌，已暫停" : job.networkRecovery?.state == .paused ? "網路恢復逾限，已暫停" : job.statusWithCompletionTime())
                        .font(.caption)
                        .foregroundStyle(statusColor)

                    // Only show a live timer while the job is running.
                    // Completed jobs stay as plain「完成」with no counting clock.
                    if job.id == viewModel.activeJobID {
                        JobElapsedView(startedAt: job.startedAt)
                    }
                    if let cloudModel = job.cloudModelSummary {
                        Text("・\(cloudModel)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let tokenSummary = job.cloudTokenSummary {
                        Text("・\(tokenSummary)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()
            actionButtons
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        if let recovery = job.serviceRecovery, recovery.state == .coolingDown || recovery.state == .retrying {
            VStack(alignment: .leading, spacing: 4) {
                Text(recovery.message).font(.caption)
                if let retryAt = recovery.nextRetryAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("約 \(max(0, Int(ceil(retryAt.timeIntervalSince(context.date))))) 秒後再嘗試；已發送 \(recovery.attempts)／4 次")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        } else if let recovery = job.networkRecovery, recovery.state == .waiting || recovery.state == .retrying {
            VStack(alignment: .leading, spacing: 4) {
                Text(recovery.message).font(.caption)
                if recovery.resultUnknown {
                    Text("前次請求的結果未知；重送可能產生重複費用。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let retryAt = recovery.nextRetryAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("約 \(max(0, Int(ceil(retryAt.timeIntervalSince(context.date))))) 秒後重試")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if recovery.state == .waiting, job.id == viewModel.activeJobID {
                    Button("立刻重試") { viewModel.retryNetworkImmediately(job.id) }
                        .controlSize(.small)
                        .disabled(!viewModel.canRetryNetworkImmediately(job.id))
                        .help("跳過目前的網路等待倒數，重新嘗試目前片段")
                }
            }
        } else if job.snapshot.backendType != .localQwen,
           job.id == viewModel.activeJobID,
           let segmentProgress = CloudSegmentProgressState(
               unit: job.progressUnit
           )
        {
            cloudSegmentProgress(segmentProgress)
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

    @ViewBuilder
    private func cloudSegmentProgress(
        _ progress: CloudSegmentProgressState
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            BreathingProgressBar(
                completedSegments: progress.completedSegments,
                totalSegments: progress.totalSegments,
                currentSegmentStartedAt: currentSegmentStartedAt,
                estimatedSegmentSeconds: estimatedSegmentSeconds,
                isCurrentSegmentInFlight: progress.phase == .preparing
                    || progress.phase == .waiting
            )

            Text(cloudSegmentProgressLabel(progress))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cloudSegmentProgressLabel(progress))
    }

    private func cloudSegmentProgressLabel(
        _ progress: CloudSegmentProgressState
    ) -> String {
        let completed = "已完成 \(progress.completedSegments)／\(progress.totalSegments) 段"
        switch progress.phase {
        case .preparing:
            return "正在準備第 \(progress.currentSegment)／\(progress.totalSegments) 段 · \(completed)"
        case .waiting:
            return "Gemini 轉錄中 · 第 \(progress.currentSegment)／\(progress.totalSegments) 段 · \(completed)"
        case .completed:
            return "Gemini \(completed)"
        case .postProcessing:
            return "所有分段已完成 · \(job.stage.displayName) · \(completed)"
        }
    }

    private var estimatedSegmentSeconds: TimeInterval {
        let latencies = job.resolvedCloudSegmentMetadata.compactMap(\.latencySeconds)
            .filter { $0 > 1 }
        if let median = Self.median(latencies) {
            return max(median, 20)
        }
        return 90
    }

    private func rememberCurrentSegment() {
        let segment = CloudSegmentProgressState(unit: job.progressUnit)?.currentSegment
        guard segment != trackedSegment else {
            return
        }
        trackedSegment = segment
        currentSegmentStartedAt = Date()
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    @ViewBuilder
    private var failureSection: some View {
        if job.snapshot.backendType != .localQwen, job.stage.isTerminal,
           job.stage != .completed || job.hasPendingGapRecovery {
            HStack {
                Button(viewModel.cloudResendStatus(job.id) ?? (cloudResumeIsAvailable ? "重送未完成片段" : "重新送出")) {
                    viewModel.resendCloudJob(job.id)
                }
                .buttonStyle(.link)
                .disabled(viewModel.cloudResendStatus(job.id) != nil)
                if job.isCloudRecoveryPaused {
                    Button("取消這筆工作") { viewModel.cancelNetworkPausedJob(job.id) }.buttonStyle(.link)
                }
            }
        }
        if job.networkRecovery?.resultUnknown == true || job.serviceRecovery?.resultUnknown == true {
            Text("先前請求結果未知，重送未完成片段可能再次計費。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        if let failure = job.failure {
            VStack(alignment: .leading, spacing: 5) {
                Text(failure.userMessage)
                    .font(.caption)
                    .foregroundStyle(
                        job.stage == .failed || job.stage == .interrupted
                            ? Color.red
                            : Color.secondary
                    )
                if failure.recoveryDirectory != nil {
                    HStack(spacing: 12) {
                        if failure.partialTranscriptPath != nil {
                            Button("打開未完成稿") {
                                viewModel.openPartialTranscript(for: job)
                            }
                        }

                        if viewModel.canResumeLocalQwenJob(job) {
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
                (job.stage == .failed || job.stage == .interrupted
                    ? Color.red
                    : Color.orange)
                    .opacity(0.07),
                in: RoundedRectangle(cornerRadius: 7)
            )
        }
    }

    @ViewBuilder
    private var logSection: some View {
        if !job.logLines.isEmpty || job.cloudDiagnostics != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let status = JobDebugClipboard.statusSummary(from: job.logLines) {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }

                HStack(spacing: 12) {
                    Button {
                        toggleLogExpansion()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isLogExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2.weight(.semibold))
                            Text(JobDebugClipboard.logToggleTitle(
                                isExpanded: isLogExpanded,
                                lineCount: job.logLines.count,
                                hasDiagnostics: job.cloudDiagnostics != nil
                            ))
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

                if isLogExpanded {
                    ExpandableDebugTextPanel(
                        text: JobDebugClipboard.expandedContent(for: job),
                        showJumpToLatest: job.logLines.count > 4
                    )
                    .padding(.top, 2)
                }
            }
        }
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
        if job.stage == .completed && job.resolvedOutputCompleteness == .hasGaps {
            return "exclamationmark.triangle.fill"
        }
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
        if job.stage == .completed && job.resolvedOutputCompleteness == .hasGaps { return .orange }
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

import RecordToTextCore
import SwiftUI

struct RecentJobRow: View {
    let summary: RecentJobSummary
    @ObservedObject var viewModel: AppViewModel
    @Binding var isDiagnosticsExpanded: Bool
    var isPrimaryCompleted: Bool = false
    var onQuickLook: ((URL) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var isDeletePresented = false
    // Filesystem stats are captured once per row (and when the summary
    // changes) instead of on every render of every row.
    @State private var fileStatus: RecentJobFileStatus = .available
    @State private var sourceIsAvailable = false
    @State private var outputIsAvailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            headerRow
            completedOutputLine
            warningsCallout
            diagnosticsSection
        }
        .padding(AppSpacing.md)
        .background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.row))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.row)
                .stroke(AppColors.hairlineBorder(colorSchemeContrast: contrast), lineWidth: 1)
        }
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
            if let outputPath = summary.outputPath, outputIsAvailable {
                Button("快速預覽（Quick Look）") {
                    onQuickLook?(URL(fileURLWithPath: outputPath))
                }
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
            if summary.cloudDiagnostics != nil {
                Button(JobDebugClipboard.recentDiagnosticsToggleTitle(isExpanded: isDiagnosticsExpanded)) {
                    toggleDiagnostics()
                }
                Button("複製除錯資訊") {
                    JobDebugClipboard.copy(summary)
                }
            }
            Divider()
            Button("從列表刪除", role: .destructive) {
                isDeletePresented = true
            }
        }
        .onAppear(perform: refreshAvailability)
        .onChange(of: summary) { _, _ in refreshAvailability() }
    }

    // MARK: - Header & Metadata

    private var headerRow: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            Image(systemName: statusSymbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.displayName)
                    .font(AppTypography.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)

                metadataLine
            }

            Spacer(minLength: AppSpacing.sm)

            HStack(spacing: AppSpacing.sm) {
                actionButtons
            }
            .fixedSize()
        }
    }

    private var metadataLine: some View {
        let backendAndModel = JobModelDisplayHelper.displayBackendAndModel(for: summary)
        let fallbackHelp = JobModelDisplayHelper.fallbackTooltip(for: summary)

        return HStack(spacing: 0) {
            Text(summary.statusWithCompletionTime())
                .foregroundStyle(statusColor)
                .fontWeight(.medium)
            Text(trailingMetadata(backendAndModel: backendAndModel))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .lineLimit(2)
        .help(fallbackHelp ?? "")
    }

    private func trailingMetadata(backendAndModel: String) -> String {
        var parts: [String] = []
        if summary.stage == .completed,
           let duration = JobModelDisplayHelper.formattedDuration(
               startedAt: summary.startedAt,
               completedAt: summary.completedAt
           )
        {
            parts.append("耗時 \(duration)")
        }
        if !backendAndModel.isEmpty {
            parts.append(backendAndModel)
        }
        if let tokens = summary.cloudTokenSummary {
            parts.append(tokens)
        }
        if let glossaryName = summary.glossaryName, !glossaryName.isEmpty {
            parts.append("詞庫：\(glossaryName)")
        }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }

    // MARK: - Output Line & Warnings

    @ViewBuilder
    private var completedOutputLine: some View {
        if summary.stage == .completed, let outputPath = summary.outputPath {
            let outputName = URL(fileURLWithPath: outputPath).lastPathComponent
            HStack(spacing: 5) {
                Image(systemName: "doc.text")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if outputIsAvailable {
                    Button {
                        viewModel.openOutput(for: summary)
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
    private var warningsCallout: some View {
        let missingFileNotice = fileStatus.displayName
        let gapReason = summary.outputGapReason
        let timestampNotice = summary.cloudDiagnostics?.timestampNotice
        let hasWarnings = missingFileNotice != nil || gapReason != nil || timestampNotice != nil

        if hasWarnings {
            InlineCallout(color: AppColors.warning) {
                VStack(alignment: .leading, spacing: 5) {
                    if let missingFileNotice {
                        Label(missingFileNotice, systemImage: "folder.badge.questionmark")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppColors.warning)
                    }
                    if let gapReason {
                        Label(gapReason, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(AppColors.warning)
                    }
                    if let timestampNotice {
                        Label(timestampNotice, systemImage: "clock.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(AppColors.warning)
                    }
                }
            }
        }
    }

    // MARK: - Diagnostics Section

    @ViewBuilder
    private var diagnosticsSection: some View {
        if summary.cloudDiagnostics != nil {
            if summary.stage != .completed || isDiagnosticsExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: AppSpacing.md) {
                        Button {
                            toggleDiagnostics()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isDiagnosticsExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                Text(JobDebugClipboard.recentDiagnosticsToggleTitle(isExpanded: isDiagnosticsExpanded))
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help(isDiagnosticsExpanded ? "收合完成工作分段診斷" : "在畫面上展開查看完成工作分段診斷")
                        .accessibilityLabel(isDiagnosticsExpanded ? "收合診斷" : "展開診斷")

                        Button("複製除錯資訊") {
                            JobDebugClipboard.copy(summary)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("複製完成工作分段診斷，方便貼給除錯用")
                    }

                    if isDiagnosticsExpanded,
                       let diagnosticsText = JobDebugClipboard.expandedContent(for: summary)
                    {
                        let isDev = viewModel.settings.developerMode
                        ExpandableDebugTextPanel(
                            text: diagnosticsText,
                            showJumpToLatest: false,
                            developerJobID: isDev ? summary.id : nil,
                            developerBadges: isDev ? JobDebugClipboard.developerBadges(for: summary) : []
                        )
                    }
                }
            }
        }
    }

    private func toggleDiagnostics() {
        if reduceMotion {
            isDiagnosticsExpanded.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.15)) {
                isDiagnosticsExpanded.toggle()
            }
        }
    }

    // MARK: - Action Buttons & Overflow Menu

    @ViewBuilder
    private var actionButtons: some View {
        if summary.stage == .completed {
            TranscriptQuickLookButton(
                outputPath: summary.outputPath,
                isOutputAvailable: outputIsAvailable
            ) { url in
                onQuickLook?(url)
            }

            if isPrimaryCompleted && outputIsAvailable {
                Button("打開文字檔") {
                    viewModel.openOutput(for: summary)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button("打開文字檔") {
                    viewModel.openOutput(for: summary)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!outputIsAvailable)
            }
        } else if sourceIsAvailable {
            Button {
                viewModel.retryRecentJob(summary)
            } label: {
                Label("重新加入", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }

        overflowMenu
    }

    private var overflowMenu: some View {
        Menu {
            if outputIsAvailable {
                Button {
                    viewModel.revealOutput(for: summary)
                } label: {
                    Label("在 Finder 顯示", systemImage: "folder")
                }
            }

            if summary.cloudDiagnostics != nil {
                Button {
                    toggleDiagnostics()
                } label: {
                    Label(
                        JobDebugClipboard.recentDiagnosticsToggleTitle(isExpanded: isDiagnosticsExpanded),
                        systemImage: "text.alignleft"
                    )
                }

                Button {
                    JobDebugClipboard.copy(summary)
                } label: {
                    Label("複製除錯資訊", systemImage: "doc.on.doc")
                }
            }

            if sourceIsAvailable {
                Button {
                    viewModel.retryRecentJob(summary)
                } label: {
                    Label("用目前設定建立新工作", systemImage: "plus.circle")
                }
            }

            Divider()

            Button(role: .destructive) {
                isDeletePresented = true
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

    // MARK: - Availability & Status Styling

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
        if summary.stage == .completed {
            if fileStatus != .available {
                return "folder.badge.questionmark"
            }
            if summary.resolvedOutputCompleteness == .hasGaps {
                return "exclamationmark.triangle.fill"
            }
            return "checkmark.circle.fill"
        }
        switch summary.stage {
        case .failed:
            return "exclamationmark.circle.fill"
        case .interrupted:
            return "arrow.clockwise.circle.fill"
        case .cancelled:
            return "minus.circle.fill"
        default:
            return "clock"
        }
    }

    private var statusColor: Color {
        if summary.stage == .completed {
            if fileStatus != .available || summary.resolvedOutputCompleteness == .hasGaps {
                return AppColors.warning
            }
            return AppColors.success
        }
        switch summary.stage {
        case .failed:
            return AppColors.danger
        case .interrupted:
            return AppColors.warning
        default:
            return AppColors.neutral
        }
    }
}

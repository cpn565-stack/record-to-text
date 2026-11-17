import RecordToTextCore
import SwiftUI

struct RecentJobRow: View {
    let summary: RecentJobSummary
    @ObservedObject var viewModel: AppViewModel
    @Binding var isDiagnosticsExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDeletePresented = false
    // Filesystem stats are captured once per row (and when the summary
    // changes) instead of on every render of every row.
    @State private var fileStatus: RecentJobFileStatus = .available
    @State private var sourceIsAvailable = false
    @State private var outputIsAvailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusList
            if isDiagnosticsExpanded,
               let diagnosticsText = JobDebugClipboard.expandedContent(for: summary)
            {
                ExpandableDebugTextPanel(
                    text: diagnosticsText,
                    showJumpToLatest: false
                )
            }
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
            if summary.cloudDiagnostics != nil {
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

                if let reason = summary.outputGapReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }
                if let notice = summary.cloudDiagnostics?.timestampNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 7) {
                    Text(summary.statusWithCompletionTime())
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
                    if let tokenSummary = summary.cloudTokenSummary {
                        Text("・\(tokenSummary)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if summary.cloudDiagnostics != nil {
                    HStack(spacing: 12) {
                        Button {
                            if reduceMotion {
                                isDiagnosticsExpanded.toggle()
                            } else {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    isDiagnosticsExpanded.toggle()
                                }
                            }
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
                    .padding(.top, 2)
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
        if fileStatus != .available || (summary.stage == .completed && summary.resolvedOutputCompleteness == .hasGaps) {
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
        if fileStatus != .available || (summary.stage == .completed && summary.resolvedOutputCompleteness == .hasGaps) {
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

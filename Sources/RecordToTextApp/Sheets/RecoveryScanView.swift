import AppKit
import RecordToTextCore
import SwiftUI

struct RecoveryScanView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var isClearAllUnsuccessfulPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                title: "復原掃描",
                subtitle: "盤點系統暫存與 Temp-Recovery；可取回部分稿、在 Finder 檢視，或清除孤立殘留。"
            ) {
                Button("關閉") {
                    viewModel.dismissRecoveryScan()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(AppSpacing.xl)

            Divider()

            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                summaryRow

                if viewModel.isRecoveryScanRunning,
                   viewModel.recoveryScanReport == nil
                {
                    ProgressView("正在掃描 App 管理的復原資料…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let report = viewModel.recoveryScanReport,
                          !report.items.isEmpty
                {
                    List {
                        ForEach(report.items) { item in
                            RecoveryScanRow(
                                item: item,
                                onOpenPartial: { viewModel.openRecoveryPartialTranscript(item) },
                                onReveal: { viewModel.revealRecoveryScanItem(item) },
                                onRequeue: { viewModel.requeueRecoverableSource(item) },
                                onDelete: { viewModel.requestDeleteRecoveryScanItem(item) }
                            )
                        }
                    }
                    .listStyle(.inset)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.row))
                } else {
                    ContentUnavailableView(
                        "沒有找到殘留資料",
                        systemImage: "checkmark.circle",
                        description: Text("系統暫存與 Temp-Recovery 皆無可顯示的 App 管理目錄。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Text("刪除僅限 App 管理的 UUID 工作目錄，且需確認。不會動到原始錄音或正式輸出的文字檔。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.vertical, AppSpacing.lg)

            Divider()

            HStack(spacing: AppSpacing.sm) {
                Button {
                    viewModel.refreshRecoveryScan()
                } label: {
                    if viewModel.isRecoveryScanRunning {
                        Label("掃描中…", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("重新掃描", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isRecoveryScanRunning)

                if hasNonRecoverableItems {
                    Button("清除孤立與損壞…", role: .destructive) {
                        viewModel.requestBulkCleanupNonRecoverable()
                    }
                    .disabled(viewModel.isRecoveryScanRunning || viewModel.isUnsuccessfulCleanupRunning)
                }

                if viewModel.hasUnsuccessfulItemsToClean {
                    Button("一鍵清除全部殘留…", role: .destructive) {
                        isClearAllUnsuccessfulPresented = true
                    }
                    .disabled(viewModel.isRecoveryScanRunning || viewModel.isUnsuccessfulCleanupRunning)
                }

                Spacer()

                if let scannedAt = viewModel.recoveryScanReport?.scannedAt {
                    Text("上次掃描：\(scannedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.vertical, AppSpacing.md)
        }
        .frame(width: 680, height: 560)
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: Binding(
                get: { viewModel.recoveryItemPendingDeletion != nil },
                set: { if !$0 { viewModel.cancelDeleteRecoveryScanItem() } }
            ),
            titleVisibility: .visible
        ) {
            Button("刪除這個目錄", role: .destructive) {
                viewModel.confirmDeleteRecoveryScanItem()
            }
            Button("取消", role: .cancel) {
                viewModel.cancelDeleteRecoveryScanItem()
            }
        } message: {
            Text(deleteDialogMessage)
        }
        .confirmationDialog(
            "清除所有孤立與損壞項目？",
            isPresented: $viewModel.isBulkCleanupConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("清除 \(nonRecoverableCount) 項", role: .destructive) {
                viewModel.confirmBulkCleanupNonRecoverable()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只會刪除「孤立暫存」與「損壞／異常」目錄，不會刪除「可取回／可重加」項目。此操作無法復原。")
        }
        .confirmationDialog(
            "一鍵清除所有未成功紀錄與殘留目錄？",
            isPresented: $isClearAllUnsuccessfulPresented,
            titleVisibility: .visible
        ) {
            Button("一鍵清除", role: .destructive) {
                Task { await viewModel.cleanUpUnsuccessfulJobsAndResidualFiles() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("將一併清除所有「失敗、已取消、被中斷」工作紀錄，以及系統暫存與 Temp-Recovery 內的全部殘留目錄（含可取回項目）。所有「完成」與「完成（含缺口）」紀錄、已輸出的 .txt 文字稿，以及原始錄音檔皆會完整保留。")
        }
    }

    private var hasNonRecoverableItems: Bool {
        nonRecoverableCount > 0
    }

    private var nonRecoverableCount: Int {
        viewModel.recoveryScanReport?.items.filter {
            $0.kind == .orphaned || $0.kind == .damaged
        }.count ?? 0
    }

    private var deleteDialogTitle: String {
        if let item = viewModel.recoveryItemPendingDeletion {
            return "刪除\(kindTitle(item.kind))？"
        }
        return "刪除復原資料？"
    }

    private var deleteDialogMessage: String {
        guard let item = viewModel.recoveryItemPendingDeletion else {
            return ""
        }
        return """
        將永久刪除：
        \(item.directoryPath)

        不會刪除原始錄音或已輸出的文字檔。
        """
    }

    private func kindTitle(_ kind: RecoveryItemKind) -> String {
        switch kind {
        case .recoverable: return "可取回／可重加資料"
        case .orphaned: return "孤立暫存"
        case .damaged: return "損壞項目"
        }
    }

    private var summaryRow: some View {
        let report = viewModel.recoveryScanReport
        return HStack(spacing: AppSpacing.md) {
            summaryChip(
                title: "可取回／可重加",
                count: report?.recoverableCount ?? 0,
                color: AppColors.warning
            )
            summaryChip(
                title: "孤立暫存",
                count: report?.orphanedCount ?? 0,
                color: AppColors.neutral
            )
            summaryChip(
                title: "損壞／異常",
                count: report?.damagedCount ?? 0,
                color: AppColors.danger
            )
            if viewModel.isRecoveryScanRunning {
                ProgressView()
                    .controlSize(.small)
                    .help("正在背景掃描")
            } else if let ignored = report?.ignoredNonUUIDDirectoryCount, ignored > 0 {
                Text("已忽略非 UUID 目錄 \(ignored) 個")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func summaryChip(title: String, count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(color.opacity(AppColors.statusTintOpacity), in: RoundedRectangle(cornerRadius: AppRadius.row))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.row)
                .stroke(color.opacity(0.22), lineWidth: 1)
        }
    }
}

private struct RecoveryScanRow: View {
    let item: RecoveryScanItem
    let onOpenPartial: () -> Void
    let onReveal: () -> Void
    let onRequeue: () -> Void
    let onDelete: () -> Void

    @State private var canRequeueSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Label(kindTitle, systemImage: kindSymbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(kindColor)
                Spacer()
                StatusBadge(text: locationTitle, color: AppColors.neutral)
            }

            Text(item.summary)
                .font(.body)

            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let source = item.sourcePath {
                Text("來源：\(source)")
                    .font(AppTypography.monoDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let sourceSlice = item.sourceSlice {
                Text("來源切片：\(sourceSlice.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(item.directoryPath)
                .font(AppTypography.monoDetail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 6) {
                if item.hasPartialTranscript {
                    StatusBadge(text: "可取回部分稿", color: AppColors.success)
                }
                if item.hasNormalizedWAV {
                    StatusBadge(text: "WAV", color: AppColors.neutral)
                }
                if item.hasRecoveryJSON {
                    StatusBadge(text: "recovery.json", color: AppColors.neutral)
                }
                if item.hasSegmentManifest {
                    StatusBadge(text: "manifest", color: AppColors.neutral)
                }

                Spacer(minLength: AppSpacing.sm)

                if item.hasPartialTranscript {
                    Button("打開部分稿", action: onOpenPartial)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button("Finder", action: onReveal)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if canRequeueSource {
                    Button("重新加入", action: onRequeue)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Button("刪除…", role: .destructive, action: onDelete)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, AppSpacing.xs)
        .onAppear(perform: refreshSourceAvailability)
        .onChange(of: item.sourcePath) { _, _ in refreshSourceAvailability() }
        .contextMenu {
            Button("複製復原資訊") {
                let text = [item.summary, item.detail, item.sourcePath, item.directoryPath]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    private func refreshSourceAvailability() {
        guard item.kind == .recoverable,
              let sourcePath = item.sourcePath,
              !sourcePath.isEmpty
        else {
            canRequeueSource = false
            return
        }
        canRequeueSource = FileManager.default.fileExists(atPath: sourcePath)
    }

    private var kindTitle: String {
        switch item.kind {
        case .recoverable: return "可取回／可重加"
        case .orphaned: return "孤立暫存"
        case .damaged: return "損壞／異常"
        }
    }

    private var kindSymbol: String {
        switch item.kind {
        case .recoverable: return "arrow.counterclockwise.circle.fill"
        case .orphaned: return "folder.badge.questionmark"
        case .damaged: return "exclamationmark.triangle.fill"
        }
    }

    private var kindColor: Color {
        switch item.kind {
        case .recoverable: return AppColors.warning
        case .orphaned: return AppColors.neutral
        case .damaged: return AppColors.danger
        }
    }

    private var locationTitle: String {
        switch item.location {
        case .systemTemp: return "系統暫存"
        case .tempRecovery: return "Temp-Recovery"
        }
    }
}

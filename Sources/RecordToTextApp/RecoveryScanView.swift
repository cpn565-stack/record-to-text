import AppKit
import RecordToTextCore
import SwiftUI

struct RecoveryScanView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            summaryRow
            if let report = viewModel.recoveryScanReport, !report.items.isEmpty {
                List {
                    ForEach(report.items) { item in
                        RecoveryScanRow(
                            item: item,
                            onReveal: { viewModel.revealRecoveryScanItem(item) },
                            onRequeue: { viewModel.requeueRecoverableSource(item) },
                            onDelete: { viewModel.requestDeleteRecoveryScanItem(item) }
                        )
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 280)
            } else {
                ContentUnavailableView(
                    "沒有找到殘留資料",
                    systemImage: "checkmark.circle",
                    description: Text("系統暫存與 Temp-Recovery 皆無可顯示的 App 管理目錄。")
                )
                .frame(maxWidth: .infinity, minHeight: 200)
            }

            Text("刪除僅限 App 管理的 UUID 工作目錄，且需確認。不會動到原始錄音或正式輸出的文字檔。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("重新掃描") {
                    viewModel.refreshRecoveryScan()
                }
                if hasNonRecoverableItems {
                    Button("清除孤立與損壞…", role: .destructive) {
                        viewModel.requestBulkCleanupNonRecoverable()
                    }
                }
                Spacer()
                Button("關閉") {
                    viewModel.dismissRecoveryScan()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
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
            Text("只會刪除「孤立暫存」與「損壞／異常」目錄，不會刪除「可復原」項目。此操作無法復原。")
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
        case .recoverable: return "可復原資料"
        case .orphaned: return "孤立暫存"
        case .damaged: return "損壞項目"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("復原掃描")
                .font(.title2.weight(.semibold))
            Text("盤點系統暫存與 Temp-Recovery；可刪除殘留或把可復原的來源音檔重新加入佇列。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var summaryRow: some View {
        let report = viewModel.recoveryScanReport
        return HStack(spacing: 16) {
            summaryChip(
                title: "可復原",
                count: report?.recoverableCount ?? 0,
                color: .orange
            )
            summaryChip(
                title: "孤立暫存",
                count: report?.orphanedCount ?? 0,
                color: .secondary
            )
            summaryChip(
                title: "損壞／異常",
                count: report?.damagedCount ?? 0,
                color: .red
            )
            if let ignored = report?.ignoredNonUUIDDirectoryCount, ignored > 0 {
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct RecoveryScanRow: View {
    let item: RecoveryScanItem
    let onReveal: () -> Void
    let onRequeue: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(kindTitle, systemImage: kindSymbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(kindColor)
                Spacer()
                Text(locationTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(item.summary)
                .font(.body)

            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let source = item.sourcePath {
                Text("來源：\(source)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            if let sourceSlice = item.sourceSlice {
                Text("來源切片：\(sourceSlice.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(item.directoryPath)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            HStack {
                if item.hasNormalizedWAV {
                    badge("WAV")
                }
                if item.hasRecoveryJSON {
                    badge("recovery.json")
                }
                if item.hasSegmentManifest {
                    badge("manifest")
                }
                Spacer()
                Button("Finder", action: onReveal)
                    .buttonStyle(.bordered)
                if item.kind == .recoverable {
                    Button("重新加入來源", action: onRequeue)
                        .buttonStyle(.borderedProminent)
                }
                Button("刪除…", role: .destructive, action: onDelete)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private var kindTitle: String {
        switch item.kind {
        case .recoverable: return "可復原"
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
        case .recoverable: return .orange
        case .orphaned: return .secondary
        case .damaged: return .red
        }
    }

    private var locationTitle: String {
        switch item.location {
        case .systemTemp: return "系統暫存"
        case .tempRecovery: return "Temp-Recovery"
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
    }
}

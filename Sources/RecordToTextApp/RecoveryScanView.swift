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
                        RecoveryScanRow(item: item) {
                            viewModel.revealRecoveryScanItem(item)
                        }
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

            Text("此掃描為唯讀：不會自動刪除任何檔案。目前僅盤點 record-to-text 管理範圍內的 UUID 工作目錄。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("重新掃描") {
                    viewModel.refreshRecoveryScan()
                }
                Spacer()
                Button("關閉") {
                    viewModel.dismissRecoveryScan()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("啟動復原掃描")
                .font(.title2.weight(.semibold))
            Text("檢查上次未清乾淨的系統暫存與 Temp-Recovery。")
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
                Button("在 Finder 顯示", action: onReveal)
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

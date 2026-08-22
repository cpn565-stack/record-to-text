import RecordToTextCore
import SwiftUI

struct EnvironmentCheckView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("環境檢查")
                        .font(.title2.weight(.semibold))
                    Text("確認轉錄引擎所需工具是否可用。雲端模式檢查 ffmpeg／ffprobe（優先使用 App 內建版本）；本機 Qwen 模式另檢查 Python、OpenCC 與 Helper。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            statusSummary

            GroupBox {
                if let report = viewModel.environmentReport {
                    VStack(spacing: 0) {
                        ForEach(Array(report.components.enumerated()), id: \.element.id) { index, component in
                            EnvironmentComponentRow(component: component)
                            if index < report.components.count - 1 {
                                Divider()
                                    .padding(.leading, 32)
                            }
                        }
                    }
                } else {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在檢查…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
            }

            HStack {
                Text("後端：\(viewModel.settings.backendType.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    viewModel.refreshEnvironment()
                } label: {
                    Label("重新檢查", systemImage: "arrow.clockwise")
                }
            }
        }
        .padding(22)
        .frame(width: 690, height: 440)
        .onAppear {
            viewModel.refreshEnvironment()
        }
    }

    @ViewBuilder
    private var statusSummary: some View {
        if let report = viewModel.environmentReport {
            HStack(spacing: 12) {
                Image(systemName: report.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(report.isReady ? Color.green : Color.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(report.isReady ? "環境已就緒" : "環境尚未完成")
                        .font(.headline)
                    Text(
                        report.isReady
                            ? (report.backendType == .googleAIStudio ? "可以開始使用 Google AI Studio (Gemini) 轉錄。" : "可以開始使用 Google Cloud Vertex AI (Gemini) 轉錄。")
                            : "缺少的元件會在下方標示。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (report.isReady ? Color.green : Color.orange).opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
    }
}

private struct EnvironmentComponentRow: View {
    let component: EnvironmentComponentReport

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: component.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(component.isAvailable ? Color.green : Color.red)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(component.component.displayName)
                        .font(.subheadline.weight(.medium))
                    Text(component.detail)
                        .font(.caption)
                        .foregroundColor(component.isAvailable ? .secondary : .red)
                }
                Text(component.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

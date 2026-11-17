import AppKit
import SwiftUI

struct PromptPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let prompt: String
    let termCount: Int
    var isJobSnapshot = false

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                title: isJobSnapshot ? "工作轉錄提示" : "轉錄提示預覽",
                subtitle: isJobSnapshot
                    ? "顯示加入時固定的內容，共 \(termCount) 個詞彙。"
                    : "詞庫與背景於加入時固定，共 \(termCount) 個詞彙。"
            ) {
                HStack(spacing: AppSpacing.sm) {
                    Button {
                        copyPrompt()
                    } label: {
                        Label(
                            copied ? "已複製" : "複製提示詞",
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(prompt.isEmpty)

                    Button("完成") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(AppSpacing.xl)

            Divider()

            ScrollView {
                Text(prompt)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppSpacing.lg)
            }
            .background(AppColors.insetSurface, in: RoundedRectangle(cornerRadius: AppRadius.row))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.row)
                    .stroke(AppColors.hairlineBorder(colorSchemeContrast: contrast), lineWidth: 1)
            }
            .padding(AppSpacing.xl)
        }
        .frame(width: 640, height: 480)
        .onDisappear {
            copyResetTask?.cancel()
        }
    }

    private func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        copied = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

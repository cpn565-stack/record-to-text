import SwiftUI

struct PromptPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let prompt: String
    let termCount: Int
    var isJobSnapshot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isJobSnapshot ? "工作轉錄提示" : "轉錄提示預覽")
                        .font(.title2.weight(.semibold))
                    Text(isJobSnapshot
                         ? "顯示加入時固定的內容，共 \(termCount) 個詞彙。"
                         : "詞庫與背景於加入時固定，共 \(termCount) 個詞彙。")
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

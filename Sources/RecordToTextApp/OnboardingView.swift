import RecordToTextCore
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var step = 0
    @State private var isEnvironmentDetailsPresented = false

    private let stepCount = 3

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                progressIndicator

                Group {
                    switch step {
                    case 0:
                        privacyStep
                    case 1:
                        outputStep
                    default:
                        environmentStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(28)

            Divider()

            HStack {
                if step > 0 {
                    Button("上一步") {
                        withAnimation(.easeOut(duration: 0.18)) {
                            step -= 1
                        }
                    }
                }

                Spacer()

                if step < stepCount - 1 {
                    Button("繼續") {
                        withAnimation(.easeOut(duration: 0.18)) {
                            step += 1
                        }
                        if step == 2 {
                            viewModel.refreshEnvironment()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("開始使用") {
                        viewModel.completeOnboarding()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 680, height: 500)
        .sheet(isPresented: $isEnvironmentDetailsPresented) {
            EnvironmentCheckView(viewModel: viewModel)
        }
    }

    private var progressIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<stepCount, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(width: index == step ? 34 : 14, height: 5)
            }
        }
        .animation(.easeOut(duration: 0.18), value: step)
        .accessibilityLabel("設定步驟 \(step + 1)，共 \(stepCount) 步")
    }

    private var privacyStep: some View {
        VStack(spacing: 22) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 58, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("選擇適合的轉錄方式")
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                Text("record-to-text 支援 Google AI Studio、Vertex AI 與本機 Qwen。雲端模式會上傳音訊；本機模式會把內容留在這台 Mac。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }

            VStack(alignment: .leading, spacing: 10) {
                OnboardingFact(
                    icon: "key.fill",
                    text: "支援 Google AI Studio API Key、Vertex AI 與本機 Qwen"
                )
                OnboardingFact(
                    icon: "waveform.badge.magnifyingglass",
                    text: "長音檔分段轉錄與順序合併，不加說話者或時間戳"
                )
                OnboardingFact(
                    icon: "character.book.closed.fill",
                    text: "輸出台灣繁體中文，並提供專有名詞提示"
                )
            }
            .padding(16)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var outputStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 54, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("選擇文字稿的家")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("預設會把所有結果放在同一個資料夾，之後可隨時到設定更改。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 470)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("目前位置")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(viewModel.settings.defaultOutputDirectory)
                    .font(.callout)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("選擇其他資料夾…") {
                    viewModel.chooseDefaultOutputDirectory()
                }
            }
            .padding(16)
            .frame(maxWidth: 520, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
    }

    private var environmentStep: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 50, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 7) {
                Text("確認轉錄環境")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("依你選擇的後端，確認音訊工具、雲端憑證或本機 Qwen Runtime。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            if let report = viewModel.environmentReport {
                HStack(spacing: 12) {
                    Image(systemName: report.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(report.isReady ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(report.isReady ? "環境已就緒" : "仍有元件尚未就緒")
                            .font(.headline)
                        Text(
                            report.isReady
                                ? "當前選擇的轉錄後端已可使用。"
                                : "你仍可先進入主畫面，稍後從「設定」或「環境檢查」處理。"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("查看詳情") {
                        isEnvironmentDetailsPresented = true
                    }
                }
                .padding(14)
                .frame(maxWidth: 520)
                .background(
                    (report.isReady ? Color.green : Color.orange).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 11)
                )
            } else {
                ProgressView("正在檢查…")
                    .controlSize(.small)
            }
        }
        .onAppear {
            viewModel.refreshEnvironment()
        }
    }
}

private struct OnboardingFact: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            Text(text)
                .font(.callout)
        }
    }
}

import RecordToTextCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var resetChoice: ResetChoice?

    var body: some View {
        TabView {
            generalSettings
                .tabItem {
                    Label("一般", systemImage: "switch.2")
                }

            outputSettings
                .tabItem {
                    Label("輸出", systemImage: "folder")
                }

            runtimeSettings
                .tabItem {
                    Label("Runtime", systemImage: "cpu")
                }

            storageSettings
                .tabItem {
                    Label("儲存", systemImage: "externaldrive")
                }
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .confirmationDialog(
            "重設 record-to-text？",
            isPresented: Binding(
                get: { resetChoice != nil },
                set: { if !$0 { resetChoice = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let resetChoice {
                Button(resetChoice.buttonTitle, role: .destructive) {
                    viewModel.resetSettings(keepGlossaries: resetChoice == .keepGlossaries)
                    self.resetChoice = nil
                }
            }
            Button("取消", role: .cancel) {
                resetChoice = nil
            }
        } message: {
            Text(resetChoice?.message ?? "")
        }
    }

    private var generalSettings: some View {
        Form {
            Section("關於此 App") {
                LabeledContent("版本") {
                    Text(appVersionLabel)
                        .textSelection(.enabled)
                }
                LabeledContent("建置") {
                    Text(appBuildLabel)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("長音預切") {
                    Text(segmentPolicyLabel)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("每段 token 上限") {
                    Text("\(defaultMaximumTokens)")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("若「長音預切」不是 20 分鐘，代表你開的不是含此改動的建置。請關閉所有視窗後改開專案 dist/record-to-text.app。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("工作流程") {
                Text("加入的檔案會先進入佇列，需按「開始轉文字」才會執行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(
                    "完成後在 Finder 顯示",
                    isOn: setting(\.revealInFinderWhenCompleted)
                )
                Toggle(
                    "完成後打開文字檔",
                    isOn: setting(\.openTextWhenCompleted)
                )
                Toggle(
                    "保留 Qwen 原始逐字稿",
                    isOn: setting(\.keepRawTranscript)
                )
            }

            Section("通知") {
                Toggle(
                    "顯示完成通知",
                    isOn: Binding(
                        get: { viewModel.settings.showNotificationWhenCompleted },
                        set: { viewModel.setNotificationPreference($0) }
                    )
                )
                Text("第一次開啟時，macOS 會詢問通知權限。未授權不影響轉錄。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var appVersionLabel: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "—"
        return short
    }

    private var appBuildLabel: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let path = Bundle.main.bundlePath
        return "\(build) · \(path)"
    }

    private var segmentPolicyLabel: String {
        let seconds = Int(AudioSegmentPlanner.productionMaximumDuration)
        let minutes = seconds / 60
        return "每段最長 \(minutes) 分鐘（\(seconds) 秒）"
    }

    private var defaultMaximumTokens: Int {
        // Keep in sync with ASRRequest default.
        16_384
    }

    private var outputSettings: some View {
        Form {
            Section("輸出位置") {
                Picker(
                    "模式",
                    selection: setting(\.outputLocationMode)
                ) {
                    ForEach(OutputLocationMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                if viewModel.settings.outputLocationMode == .fixedDirectory {
                    LabeledContent("預設資料夾") {
                        HStack(spacing: 8) {
                            Text(viewModel.settings.defaultOutputDirectory)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 320, alignment: .trailing)
                            Button("選擇…") {
                                viewModel.chooseDefaultOutputDirectory()
                            }
                        }
                    }
                }

                Text(outputModeHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("檔案") {
                TextField(
                    "檔名後綴",
                    text: Binding(
                        get: {
                            viewModel.settings.outputFilenameSuffix
                                ?? OutputNameBuilder.defaultFinalSuffix
                        },
                        set: { newValue in
                            viewModel.setSetting(
                                \.outputFilenameSuffix,
                                to: OutputNameBuilder.sanitizedSuffix(
                                    newValue,
                                    fallback: OutputNameBuilder.defaultFinalSuffix
                                )
                            )
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)

                LabeledContent("預覽") {
                    Text(
                        OutputNameBuilder.previewFileName(
                            suffix: viewModel.settings.resolvedOutputFilenameSuffix
                        )
                    )
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }

                if viewModel.settings.keepRawTranscript {
                    TextField(
                        "原始稿後綴",
                        text: Binding(
                            get: {
                                viewModel.settings.rawFilenameSuffix
                                    ?? OutputNameBuilder.defaultRawSuffix
                            },
                            set: { newValue in
                                viewModel.setSetting(
                                    \.rawFilenameSuffix,
                                    to: OutputNameBuilder.sanitizedSuffix(
                                        newValue,
                                        fallback: OutputNameBuilder.defaultRawSuffix
                                    )
                                )
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    LabeledContent("原始稿預覽") {
                        Text(
                            OutputNameBuilder.previewFileName(
                                suffix: viewModel.settings.resolvedRawFilenameSuffix
                            )
                        )
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    }
                }

                Text("規則：原檔名 + 後綴 + .txt。若檔名已存在，自動加上 _2、_3…")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("格式") {
                    Text("UTF-8・LF・無 BOM")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var runtimeSettings: some View {
        Form {
            Section("目前架構") {
                LabeledContent("電腦") {
                    Text(CPUArchitecture.current == .x86_64 ? "Intel" : "Apple Silicon")
                }

                Picker(
                    "模型",
                    selection: Binding(
                        get: { viewModel.settings.selectedModelID },
                        set: { viewModel.setSelectedModelID($0) }
                    )
                ) {
                    ForEach(viewModel.availableModels) { model in
                        Text(model.displayName).tag(model.id)
                    }
                    if !viewModel.availableModels.contains(where: {
                        $0.id == viewModel.settings.selectedModelID
                    }) {
                        Text(viewModel.settings.selectedModelID)
                            .tag(viewModel.settings.selectedModelID)
                    }
                }
                .disabled(viewModel.modelDownloadPhase.isBusy)

                HStack(spacing: 10) {
                    Button(viewModel.modelDownloadButtonTitle) {
                        viewModel.downloadSelectedModel()
                    }
                    .disabled(!viewModel.canDownloadSelectedModel)

                    if viewModel.modelDownloadPhase.isBusy {
                        ProgressView()
                            .controlSize(.small)
                        Button("取消") {
                            viewModel.cancelModelDownload()
                        }
                    } else if viewModel.isSelectedModelCached {
                        Label("App 模型目錄已就緒", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if viewModel.isSelectedModelInDefaultHFCache {
                        Label("本機 Hugging Face cache 可匯入", systemImage: "externaldrive.fill.badge.checkmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("模型 ID") {
                    Text(viewModel.settings.selectedModelID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }

                if let detail = viewModel.selectedModelDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !viewModel.modelDownloadProgressLine.isEmpty {
                    Text(viewModel.modelDownloadProgressLine)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }

                switch viewModel.modelDownloadPhase {
                case let .succeeded(message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.green)
                case let .failed(message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                case .idle, .importingLocal, .downloading:
                    EmptyView()
                }

                Text("下載位置：App 的 Models 目錄。若 ~/.cache/huggingface 已有同模型，會優先本機匯入，避免重複下載。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if CPUArchitecture.current == .x86_64 {
                    Label(
                        "Intel CPU backend 尚未完成實機驗證，目前為 Experimental。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else if viewModel.settings.selectedModelID
                    == ASRModelDescriptor.appleSiliconBF16.id
                {
                    Text("BF16 體積較大，並需要更多統一記憶體。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onAppear {
                viewModel.refreshSelectedModelCacheStatus()
            }

            Section("Developer Mode") {
                Toggle(
                    "使用本機開發環境",
                    isOn: Binding(
                        get: { viewModel.settings.developerMode },
                        set: {
                            viewModel.setSetting(\.developerMode, to: $0)
                            viewModel.refreshEnvironment()
                        }
                    )
                )

                if viewModel.settings.developerMode {
                    TextField(
                        CPUArchitecture.current == .x86_64
                            ? "Python 路徑（留白使用 ~/record-to-text-intel-env）"
                            : "Python 路徑（留白使用 ~/mlx-audio-env）",
                        text: optionalStringSetting(\.customPythonPath)
                    )
                    TextField(
                        "Helper 路徑（留白使用 App 內建 helper）",
                        text: optionalStringSetting(\.customHelperPath)
                    )
                }

                Text("Developer Mode 僅供本機驗證；正式版本會使用 App 管理且已驗證的 Runtime。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("執行環境檢查…") {
                    viewModel.refreshEnvironment()
                    viewModel.isEnvironmentPresented = true
                }
            }
        }
        .formStyle(.grouped)
    }

    private var storageSettings: some View {
        Form {
            Section("最近工作") {
                Stepper(
                    "保留 \(viewModel.settings.recentJobLimit) 筆",
                    value: setting(\.recentJobLimit),
                    in: 0...50
                )

                Button("清除已完成與失敗的記錄") {
                    viewModel.clearRecentJobs()
                }
                .disabled(
                    viewModel.recentJobs.isEmpty
                        && !viewModel.jobs.contains(where: { $0.stage.isTerminal })
                )

                Text("清除記錄不會刪除錄音、文字檔或失敗時保留的 WAV。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("App 資料") {
                LabeledContent("位置") {
                    Text(viewModel.applicationSupportURL.path)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button("在 Finder 顯示") {
                    viewModel.revealApplicationSupport()
                }
            }

            Section("重設") {
                Button("重設設定，保留詞庫…") {
                    resetChoice = .keepGlossaries
                }
                Button("重設設定與詞庫…", role: .destructive) {
                    resetChoice = .everything
                }
            }
        }
        .formStyle(.grouped)
    }

    private var outputModeHelp: String {
        switch viewModel.settings.outputLocationMode {
        case .fixedDirectory:
            return "所有工作輸出到同一個資料夾。"
        case .sameAsSource:
            return "每個文字檔會放在原始錄音旁邊。"
        case .askEveryTime:
            return "每次加入一批錄音時選擇一次輸出資料夾。"
        }
    }

    private func setting<Value>(
        _ keyPath: WritableKeyPath<AppSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { viewModel.settings[keyPath: keyPath] },
            set: { viewModel.setSetting(keyPath, to: $0) }
        )
    }

    private func optionalStringSetting(
        _ keyPath: WritableKeyPath<AppSettings, String?>
    ) -> Binding<String> {
        Binding(
            get: { viewModel.settings[keyPath: keyPath] ?? "" },
            set: {
                let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                viewModel.setSetting(keyPath, to: value.isEmpty ? nil : value)
            }
        )
    }
}

private enum ResetChoice {
    case keepGlossaries
    case everything

    var buttonTitle: String {
        switch self {
        case .keepGlossaries:
            return "重設設定"
        case .everything:
            return "重設設定與詞庫"
        }
    }

    var message: String {
        switch self {
        case .keepGlossaries:
            return "一般、輸出與 Runtime 設定會回到預設值，詞庫會保留。"
        case .everything:
            return "設定與所有詞庫都會清除。既有錄音與文字檔不受影響。"
        }
    }
}

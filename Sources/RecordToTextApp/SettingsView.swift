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
        .frame(width: 620, height: 470)
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
            Section("工作流程") {
                Toggle(
                    "加入檔案後自動開始",
                    isOn: setting(\.autoStartAfterSelection)
                )
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
                LabeledContent("最終文字檔") {
                    Text("原檔名_繁體.txt")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("同名檔案") {
                    Text("自動加上 _2、_3…")
                        .foregroundStyle(.secondary)
                }
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
                LabeledContent("模型") {
                    Text(viewModel.selectedModelName)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                TextField(
                    "模型 ID",
                    text: Binding(
                        get: { viewModel.settings.selectedModelID },
                        set: { viewModel.setSelectedModelID($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)

                if CPUArchitecture.current == .x86_64 {
                    Label(
                        "Intel CPU backend 尚未完成實機驗證，目前為 Experimental。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
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

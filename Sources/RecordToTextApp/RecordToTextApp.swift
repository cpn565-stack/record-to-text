import AppKit
import SwiftUI

@MainActor
final class RecordToTextAppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: AppViewModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel else {
            return .terminateNow
        }
        guard viewModel.hasActiveJob else {
            viewModel.flushPendingSettingsPersistence()
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "轉錄仍在進行"
        alert.informativeText = "現在離開會停止目前工作。佇列中的其他工作也不會繼續執行。"
        alert.addButton(withTitle: "繼續轉錄")
        alert.addButton(withTitle: "停止工作並離開")

        guard alert.runModal() == .alertSecondButtonReturn else {
            return .terminateCancel
        }

        Task { @MainActor in
            await viewModel.stopAllForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
@MainActor
struct RecordToTextApp: App {
    @NSApplicationDelegateAdaptor(RecordToTextAppDelegate.self)
    private var appDelegate

    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup("record-to-text") {
            MainView(viewModel: viewModel)
                .frame(minWidth: 760, minHeight: 680)
                .onAppear {
                    appDelegate.viewModel = viewModel
                }
        }
        .defaultSize(width: 900, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("選擇錄音檔…") {
                    viewModel.chooseAudioFiles()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandMenu("轉錄") {
                Button("開始轉文字") {
                    viewModel.startQueuedJobs()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!viewModel.hasQueuedJobs)

                Button("取消目前工作") {
                    viewModel.cancelCurrentJob()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!viewModel.hasActiveJob)

                Divider()

                Button("環境檢查…") {
                    viewModel.refreshEnvironment()
                    viewModel.isEnvironmentPresented = true
                }
            }
        }

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }
}

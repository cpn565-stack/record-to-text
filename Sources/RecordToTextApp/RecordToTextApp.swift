import AppKit
import SwiftUI

@MainActor
final class RecordToTextAppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: AppViewModel?
    private var terminationPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        guard let viewModel else {
            return .terminateNow
        }
        if viewModel.hasActiveJob {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "轉錄仍在進行"
        alert.informativeText = "現在離開會停止目前工作。佇列中的其他工作也不會繼續執行。"
        alert.addButton(withTitle: "繼續轉錄")
        alert.addButton(withTitle: "停止工作並離開")

        guard alert.runModal() == .alertSecondButtonReturn else {
            return .terminateCancel
        }

        }
        terminationPending = true
        Task { @MainActor in
            await viewModel.stopAllForTermination()
            while true {
                do {
                    try await viewModel.saveLatestJobsForTermination()
                    sender.reply(toApplicationShouldTerminate: true)
                    return
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "工作紀錄尚未儲存"
                    alert.informativeText = "儲存失敗或超過 5 秒。仍然退出可能遺失最新工作狀態。"
                    alert.addButton(withTitle: "重試儲存")
                    alert.addButton(withTitle: "取消退出")
                    alert.addButton(withTitle: "仍然退出")
                    switch alert.runModal() {
                    case .alertFirstButtonReturn: continue
                    case .alertSecondButtonReturn:
                        self.terminationPending = false
                        sender.reply(toApplicationShouldTerminate: false)
                    default: sender.reply(toApplicationShouldTerminate: true)
                    }
                    return
                }
            }
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

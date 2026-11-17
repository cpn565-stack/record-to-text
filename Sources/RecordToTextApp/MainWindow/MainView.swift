import AppKit
import RecordToTextCore
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var isDropTargeted = false
    @State private var logExpansion = JobLogExpansionState()
    @State private var recentDiagnosticsExpansion = JobLogExpansionState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                titleBlock
                if let error = viewModel.jobPersistenceError {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("工作紀錄尚未儲存").font(.headline)
                            Text(error).font(.caption).textSelection(.enabled)
                        }
                        Spacer()
                        Button("重試儲存") { Task { await viewModel.retryJobPersistence() } }
                    }
                    .foregroundStyle(.orange)
                }
                ComposerView(viewModel: viewModel, isDropTargeted: isDropTargeted)
                JobListView(
                    viewModel: viewModel,
                    logExpansion: $logExpansion,
                    recentDiagnosticsExpansion: $recentDiagnosticsExpansion
                )
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        // Keep one file-drop destination on the entire viewport, including
        // the queue and empty margins. Finder supplies `public.file-url`;
        // preserve the explicit provider decoding used by the import flow.
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .overlay(alignment: .top) {
                        Label("放開以加入錄音佇列", systemImage: "arrow.down.doc.fill")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.top, 12)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    viewModel.isGlossaryManagerPresented = true
                } label: {
                    Label("詞庫管理", systemImage: "text.book.closed")
                }
                .help("詞庫管理：編輯共用詞彙與專案詞庫，供轉錄 Prompt 使用")
                .accessibilityLabel("詞庫管理")
                .accessibilityHint("開啟詞庫管理視窗")

                Button {
                    viewModel.refreshEnvironment()
                    viewModel.isEnvironmentPresented = true
                } label: {
                    Label("環境檢查", systemImage: "checkmark.shield")
                }
                .help("環境檢查：確認 ffmpeg／ffprobe 是否就緒（Google AI Studio 使用 App 內建版本）")
                .accessibilityLabel("環境檢查")
                .accessibilityHint("開啟執行環境檢查")

                Button {
                    viewModel.refreshRecoveryScan()
                } label: {
                    Label("復原掃描", systemImage: "externaldrive.badge.timemachine")
                }
                .help("復原掃描：檢查系統暫存與 Temp-Recovery，可刪除殘留或重新加入來源音檔")
                .accessibilityLabel("復原掃描")
                .accessibilityHint("掃描並管理未清理的暫存與復原資料")

                SettingsLink {
                    Label("設定", systemImage: "gearshape")
                }
                .help("設定：輸出位置、檔名後綴、模型選擇、通知與 Developer Mode")
                .accessibilityLabel("設定")
                .accessibilityHint("開啟 App 設定")
            }
        }
        .sheet(isPresented: $viewModel.isPromptPreviewPresented) {
            PromptPreviewView(
                prompt: viewModel.promptPreview,
                termCount: viewModel.promptTermCount
            )
        }
        .sheet(isPresented: $viewModel.isGlossaryManagerPresented) {
            GlossaryManagerView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isEnvironmentPresented) {
            EnvironmentCheckView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isRecoveryScanPresented) {
            RecoveryScanView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isOnboardingPresented) {
            OnboardingView(viewModel: viewModel)
                .interactiveDismissDisabled()
        }
        .alert(item: $viewModel.alert) { item in
            Alert(
                title: Text(item.title),
                message: Text(item.message),
                dismissButton: .default(Text("好"))
            )
        }
        .confirmationDialog(
            "這些檔案已在佇列中",
            isPresented: $viewModel.isDuplicateConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("仍然加入") {
                viewModel.confirmDuplicateFiles()
            }
            Button("略過重複檔案", role: .cancel) {
                viewModel.discardDuplicateFiles()
            }
        } message: {
            Text("重複加入會各自產生一份工作與輸出檔。")
        }
        .confirmationDialog(
            "目前後端不支援專有名詞提示",
            isPresented: Binding(
                get: { viewModel.isPromptConsentPresented },
                set: { isPresented in
                    if !isPresented, viewModel.isPromptConsentPresented {
                        viewModel.declineRetryWithoutGlossaryPrompt()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("不用詞庫重試") {
                viewModel.retryWithoutGlossaryPrompt()
            }
            Button("保留失敗狀態", role: .cancel) {
                viewModel.declineRetryWithoutGlossaryPrompt()
            }
        } message: {
            Text("只有明確選擇後，record-to-text 才會在不套用專有名詞的情況下重試。")
        }
    }

    private var titleBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("record-to-text")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                Text(viewModel.appSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if viewModel.isWaitingForStartup {
                    Text("正在載入啟動資料，完成後會開始")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("取消開始", action: viewModel.cancelPendingStart)
                        .buttonStyle(.link)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("新錄音與尚未開始的工作")
                    .font(.caption2).foregroundStyle(.secondary)
                QuickModelMenu(viewModel: viewModel)
                if viewModel.selectedQuickTranscriptionChoice == .aiStudioGemini35Transcribe ||
                    viewModel.selectedQuickTranscriptionChoice == .vertexGemini35Transcribe {
                    Text("專用轉錄：有詞庫時不區分講者；不使用背景與自訂提示")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let active = viewModel.jobs.first(where: { $0.id == viewModel.activeJobID }) {
                    Text("正在執行：\(active.snapshot.engineDisplayName)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("切換選單不會改變執行中或檢查點續跑的工作")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else {
            return false
        }

        viewModel.beginFileImport()
        Task { @MainActor in
            defer { viewModel.endFileImport() }
            let urls = await Self.fileURLs(from: providers)
            viewModel.addFiles(urls)
        }
        return true
    }

    private static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            guard let url = await fileURL(from: provider) else {
                continue
            }
            urls.append(url)
        }
        return urls
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, _ in
                continuation.resume(returning: parseDroppedFileURL(item))
            }
        }
    }

    private static func parseDroppedFileURL(_ item: NSSecureCoding?) -> URL? {
        if let url = item as? URL, url.isFileURL {
            return url
        }
        if let url = item as? NSURL, url.isFileURL {
            return url as URL
        }
        if let string = item as? String {
            return parseDroppedFileURLString(string)
        }
        if let data = item as? Data {
            return parseDroppedFileURLString(String(decoding: data, as: UTF8.self))
        }
        return nil
    }

    private static func parseDroppedFileURLString(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if let url = URL(string: trimmed), url.isFileURL {
            return url
        }
        let url = URL(fileURLWithPath: trimmed)
        return url.isFileURL ? url : nil
    }
}

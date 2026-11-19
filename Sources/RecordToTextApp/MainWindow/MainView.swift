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
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                if let error = viewModel.jobPersistenceError {
                    persistenceErrorCallout(error)
                }

                if viewModel.isWaitingForStartup {
                    waitingForStartupCallout
                }

                ComposerView(viewModel: viewModel, isDropTargeted: isDropTargeted)

                JobListView(
                    viewModel: viewModel,
                    logExpansion: $logExpansion,
                    recentDiagnosticsExpansion: $recentDiagnosticsExpansion
                )
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(.horizontal, AppSpacing.xxl)
            .padding(.vertical, AppSpacing.xl)
            .frame(maxWidth: .infinity)
        }
        .background(AppColors.windowBackground)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if QueueActionBar.shouldShow(for: viewModel) {
                QueueActionBar(viewModel: viewModel)
            }
        }
        .contentShape(Rectangle())
        // Keep one file-drop destination on the entire viewport, including
        // the queue and empty margins. Finder supplies `public.file-url`;
        // preserve the explicit provider decoding used by the import flow.
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: AppRadius.composer)
                    .strokeBorder(AppColors.accent, lineWidth: 2)
                    .padding(AppSpacing.xs)
                    .overlay(alignment: .top) {
                        Label("放開以加入錄音佇列", systemImage: "arrow.down.doc.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(AppColors.accent)
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(.vertical, 10)
                            .adaptiveGlassSurface(in: Capsule())
                            .padding(.top, AppSpacing.md)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .navigationSubtitle(navigationSubtitleText)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ToolbarModelMenu(viewModel: viewModel)

                Button {
                    viewModel.isGlossaryManagerPresented = true
                } label: {
                    Label("詞庫管理", systemImage: "text.book.closed")
                }
                .help("詞庫管理（⌘⇧L）：編輯共用詞彙與專案詞庫")
                .accessibilityLabel("詞庫管理")
                .accessibilityHint("開啟詞庫管理視窗")

                ToolbarToolsMenu(viewModel: viewModel)

                SettingsLink {
                    Label("設定", systemImage: "gearshape")
                }
                .help("設定（⌘,）：輸出位置、轉錄引擎、模型與進階選項")
                .accessibilityLabel("設定")
                .accessibilityHint("開啟 App 設定")
            }
        }
        .sheet(isPresented: $viewModel.isPromptPreviewPresented) {
            PromptPreviewView(
                prompt: viewModel.promptPreview,
                termCount: viewModel.promptTermCount
            )
            .tint(AppColors.accent)
        }
        .sheet(isPresented: $viewModel.isGlossaryManagerPresented) {
            GlossaryManagerView(viewModel: viewModel)
                .tint(AppColors.accent)
        }
        .sheet(isPresented: $viewModel.isEnvironmentPresented) {
            EnvironmentCheckView(viewModel: viewModel)
                .tint(AppColors.accent)
        }
        .sheet(isPresented: $viewModel.isRecoveryScanPresented) {
            RecoveryScanView(viewModel: viewModel)
                .tint(AppColors.accent)
        }
        .sheet(isPresented: $viewModel.isOnboardingPresented) {
            OnboardingView(viewModel: viewModel)
                .tint(AppColors.accent)
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
        .confirmationDialog(
            "一鍵清除未成功項目與殘留檔？",
            isPresented: $viewModel.isUnsuccessfulCleanupConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("一鍵清除", role: .destructive) {
                Task { await viewModel.cleanUpUnsuccessfulJobsAndResidualFiles() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(unsuccessfulCleanupConfirmationMessage)
        }
        .tint(AppColors.accent)
    }

    private var unsuccessfulCleanupConfirmationMessage: String {
        let recordCount = viewModel.unsuccessfulJobCount
        let dirCount = viewModel.cleanableRecoveryItemCount
        var targets: [String] = []
        if recordCount > 0 {
            targets.append("\(recordCount) 筆未成功紀錄（失敗／取消／中斷）")
        }
        if dirCount > 0 {
            targets.append("\(dirCount) 個系統暫存／Temp-Recovery 殘留目錄")
        }
        let summary = targets.isEmpty
            ? "將清除所有未成功紀錄與 App 暫存／Temp-Recovery 殘留目錄。"
            : "將一併清除 " + targets.joined(separator: " 與 ") + "。"
        return "\(summary)\n\n所有「完成」與「完成（含缺口）」紀錄、已輸出的 .txt 文字稿，以及原始錄音檔皆會完整保留。"
    }

    private var navigationSubtitleText: String {
        if viewModel.isWaitingForStartup {
            return "正在載入啟動資料，完成後會開始"
        }
        if let active = viewModel.activeJob {
            let totalPending = max(1, 1 + viewModel.queuedJobCount)
            if totalPending > 1 {
                return "轉錄中（1／\(totalPending)）：\(active.displayName)"
            }
            return "轉錄中：\(active.displayName)"
        }
        if viewModel.jobs.contains(where: \.isCloudRecoveryPaused) {
            return "已暫停 · 等待恢復或手動重送"
        }
        if viewModel.hasQueuedJobs {
            let backend = JobModelDisplayHelper.shortBackendName(viewModel.settings.backendType)
            return "等待中 \(viewModel.queuedJobCount) 筆 · 準備使用 \(backend)"
        }
        return "就緒 · \(JobModelDisplayHelper.currentEngineSummary(viewModel.settings))"
    }

    private func persistenceErrorCallout(_ error: String) -> some View {
        InlineCallout(color: AppColors.warning) {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text("工作紀錄尚未儲存")
                        .font(.subheadline.weight(.semibold))
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("重試儲存") {
                    Task { await viewModel.retryJobPersistence() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var waitingForStartupCallout: some View {
        InlineCallout(color: AppColors.accent) {
            HStack(spacing: AppSpacing.md) {
                ProgressView()
                    .controlSize(.small)
                Text("正在載入啟動資料，完成後會開始")
                    .font(AppTypography.rowMeta)
                Spacer()
                Button("取消開始", action: viewModel.cancelPendingStart)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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

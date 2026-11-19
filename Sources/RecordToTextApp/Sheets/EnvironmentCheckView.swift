import AppKit
import RecordToTextCore
import SwiftUI

struct EnvironmentCheckView: View {
    @ObservedObject var viewModel: AppViewModel
    var showsOpenSettingsButton = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                title: "環境檢查",
                subtitle: "確認目前轉錄引擎所需的音訊工具、憑證與執行環境是否就緒。"
            ) {
                HStack(spacing: AppSpacing.sm) {
                    Button {
                        viewModel.refreshEnvironment()
                        if viewModel.settings.backendType == .localQwen {
                            viewModel.refreshSelectedModelCacheStatus()
                        }
                    } label: {
                        Label("重新檢查", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

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
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    statusSummary

                    if viewModel.settings.backendType == .localQwen,
                       !viewModel.settings.developerMode
                    {
                        InlineCallout(color: AppColors.warning) {
                            HStack(alignment: .center, spacing: AppSpacing.md) {
                                Label(
                                    "目前選用受管理 Runtime，必須通過簽章與完整性驗證才會執行。",
                                    systemImage: "lock.shield"
                                )
                                .font(.callout)

                                Spacer()

                                Button("切換開發 Runtime") {
                                    enableDeveloperRuntime()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }

                    componentListCard

                    supplementaryReadinessCard
                }
                .padding(AppSpacing.xl)
            }

            Divider()

            HStack {
                Text(
                    viewModel.settings.backendType == .localQwen
                        ? "目前後端：\(viewModel.settings.backendType.displayName) · \(viewModel.runtimeModeDescription)"
                        : "目前後端：\(viewModel.settings.backendType.displayName)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                if showsOpenSettingsButton {
                    Button("開啟設定…") {
                        dismiss()
                        openSettings()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.vertical, AppSpacing.md)
        }
        .frame(width: 680, height: 520)
        .onAppear {
            viewModel.refreshEnvironment()
            if viewModel.settings.backendType == .localQwen {
                viewModel.refreshSelectedModelCacheStatus()
            }
        }
    }

    private var isFullyReadyForSelectedBackend: Bool {
        guard let report = viewModel.environmentReport, report.isReady else {
            return false
        }
        switch viewModel.settings.backendType {
        case .googleAIStudio:
            let hasKey = !(viewModel.settings.googleAIStudioAPIKey?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            return hasKey
        case .vertexAI:
            return true
        case .localQwen:
            return viewModel.isSelectedModelCached
        }
    }

    @ViewBuilder
    private var statusSummary: some View {
        if let report = viewModel.environmentReport {
            let allReady = isFullyReadyForSelectedBackend
            InlineCallout(color: allReady ? AppColors.success : AppColors.warning) {
                HStack(spacing: AppSpacing.md) {
                    Image(systemName: allReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(allReady ? AppColors.success : AppColors.warning)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(allReady ? "環境已就緒" : "仍有項目待完成")
                            .font(.headline)
                        Text(summarySubtitle(report: report, allReady: allReady))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
            }
        }
    }

    private func summarySubtitle(report: EnvironmentReport, allReady: Bool) -> String {
        if allReady {
            switch report.backendType {
            case .googleAIStudio:
                return "音訊工具與 Google AI Studio API Key 皆已備妥，可直接開始轉錄。"
            case .vertexAI:
                return "音訊工具與 gcloud CLI 已就緒，可直接開始 Vertex AI 轉錄。"
            case .localQwen:
                return "本機 Qwen Runtime 與模型快取皆已就緒，可離線轉錄。"
            }
        }
        if !report.isReady {
            return report.backendType == .localQwen && !report.isDeveloperRuntime
                ? "受管理 Runtime 尚未驗證，或缺少必要元件；可切換開發 Runtime 或安裝缺少工具。"
                : "請依下方標示補齊缺少的工具元件。"
        }
        if report.backendType == .googleAIStudio {
            return "執行工具已就緒，但尚未設定 Google AI Studio API Key。"
        }
        return "執行工具已就緒，但尚未下載或匯入本機 Qwen 模型。"
    }

    private var componentListCard: some View {
        VStack(spacing: 0) {
            if let report = viewModel.environmentReport {
                ForEach(Array(report.components.enumerated()), id: \.element.id) { index, component in
                    EnvironmentComponentRow(
                        component: component,
                        canSwitchToDeveloperRuntime: viewModel.settings.backendType == .localQwen
                            && !viewModel.settings.developerMode,
                        onSwitchDeveloperRuntime: enableDeveloperRuntime
                    )
                    if index < report.components.count - 1 {
                        Divider()
                            .padding(.leading, 36)
                    }
                }
            } else {
                HStack(spacing: AppSpacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在檢查執行環境…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(AppSpacing.xl)
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.xs)
        .background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.card)
                .stroke(AppColors.hairlineBorder(colorSchemeContrast: contrast), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var supplementaryReadinessCard: some View {
        switch viewModel.settings.backendType {
        case .googleAIStudio:
            let hasKey = !(viewModel.settings.googleAIStudioAPIKey?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            supplementaryRow(
                title: "Google AI Studio API Key",
                detail: viewModel.googleAIStudioCredentialStorageDescription,
                badgeText: hasKey ? "就緒" : "未設定",
                badgeColor: hasKey ? AppColors.success : AppColors.warning,
                actionTitle: (hasKey || !showsOpenSettingsButton) ? nil : "前往設定…"
            ) {
                dismiss()
                openSettings()
            }

        case .localQwen:
            let ready = viewModel.isSelectedModelCached
            supplementaryRow(
                title: "Qwen 模型快取（\(viewModel.settings.selectedModelID)）",
                detail: ready
                    ? "App 模型目錄已包含可用 snapshot。"
                    : (viewModel.isSelectedModelInDefaultHFCache
                        ? "偵測到 ~/.cache/huggingface 有同模型，可於設定一鍵匯入。"
                        : "尚未下載模型；請至「設定 → 轉錄引擎」下載。"),
                badgeText: ready ? "就緒" : "需準備",
                badgeColor: ready ? AppColors.success : AppColors.warning,
                actionTitle: (ready || !showsOpenSettingsButton) ? nil : "前往設定…"
            ) {
                dismiss()
                openSettings()
            }

        case .vertexAI:
            EmptyView()
        }
    }

    private func supplementaryRow(
        title: String,
        detail: String,
        badgeText: String,
        badgeColor: Color,
        actionTitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: badgeColor == AppColors.success ? "checkmark.circle.fill" : "key.fill")
                .foregroundStyle(badgeColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: AppSpacing.sm) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                    StatusBadge(text: badgeText, color: badgeColor)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(AppSpacing.md)
        .background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.card)
                .stroke(AppColors.hairlineBorder(colorSchemeContrast: contrast), lineWidth: 1)
        }
    }

    private func enableDeveloperRuntime() {
        viewModel.setSetting(\.customPythonPath, to: nil)
        viewModel.setSetting(\.customHelperPath, to: nil)
        viewModel.setSetting(\.developerMode, to: true)
        viewModel.refreshEnvironment()
    }
}

private struct EnvironmentComponentRow: View {
    let component: EnvironmentComponentReport
    let canSwitchToDeveloperRuntime: Bool
    let onSwitchDeveloperRuntime: () -> Void

    @State private var copiedInstallCommand = false

    private var isUnverified: Bool {
        !component.isAvailable && component.detail.contains("驗證")
    }

    private var badgeInfo: (text: String, color: Color) {
        if component.isAvailable {
            return ("就緒", AppColors.success)
        }
        if isUnverified {
            return ("未驗證", AppColors.warning)
        }
        return ("缺少", AppColors.danger)
    }

    private var installCommandHint: String? {
        guard !component.isAvailable else { return nil }
        switch component.component {
        case .opencc:
            return "brew install opencc"
        case .gcloud:
            return "brew install --cask google-cloud-sdk"
        case .ffmpeg, .ffprobe:
            return "brew install ffmpeg"
        case .python, .helper:
            return nil
        }
    }

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Image(
                systemName: component.isAvailable
                    ? "checkmark.circle.fill"
                    : (isUnverified ? "exclamationmark.shield.fill" : "xmark.circle.fill")
            )
            .foregroundStyle(badgeInfo.color)
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: AppSpacing.sm) {
                    Text(component.component.displayName)
                        .font(.subheadline.weight(.medium))
                    StatusBadge(text: badgeInfo.text, color: badgeInfo.color)
                    Text(component.detail)
                        .font(.caption)
                        .foregroundStyle(component.isAvailable ? .secondary : badgeInfo.color)
                        .lineLimit(1)
                }
                Text(component.path)
                    .font(AppTypography.monoDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer()

            if !component.isAvailable {
                if let command = installCommandHint {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copiedInstallCommand = true
                    } label: {
                        Text(copiedInstallCommand ? "已複製指令" : "複製安裝提示")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("複製終端機安裝指令：\(command)")
                } else if canSwitchToDeveloperRuntime,
                          component.component == .python || component.component == .helper
                {
                    Button("切換開發 Runtime", action: onSwitchDeveloperRuntime)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

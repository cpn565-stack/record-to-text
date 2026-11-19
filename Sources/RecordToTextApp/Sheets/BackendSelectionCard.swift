import RecordToTextCore
import SwiftUI

/// Visual 3-card selector shared by `SettingsView` ("轉錄引擎" tab) and `OnboardingView` (Step 1).
struct BackendSelectionRow: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            ForEach(ASRBackendType.allCases, id: \.self) { backend in
                BackendSelectionCard(
                    backend: backend,
                    isSelected: viewModel.settings.backendType == backend,
                    badge: statusBadge(for: backend)
                ) {
                    guard viewModel.settings.backendType != backend else { return }
                    viewModel.setSetting(\.backendType, to: backend)
                    if backend == .localQwen {
                        viewModel.refreshSelectedModelCacheStatus()
                    }
                    viewModel.refreshEnvironment()
                }
            }
        }
    }

    private func statusBadge(for backend: ASRBackendType) -> (text: String, color: Color) {
        switch backend {
        case .googleAIStudio:
            if viewModel.isGoogleAIStudioCredentialLoading {
                return ("讀取中", AppColors.neutral)
            }
            switch viewModel.googleAIStudioCredentialStorageState {
            case .stored:
                return ("已存 Key", AppColors.success)
            case .memoryOnly:
                return ("暫存 Key", AppColors.warning)
            case .absent, .unavailable:
                let hasInMemory = !(viewModel.settings.googleAIStudioAPIKey?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                return hasInMemory ? ("暫存 Key", AppColors.warning) : ("未設定", AppColors.warning)
            }

        case .vertexAI:
            let hasExplicitProject = !(viewModel.settings.vertexAIProjectID?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            if hasExplicitProject {
                return ("已設定專案", AppColors.success)
            }
            if let report = viewModel.environmentReport,
               report.backendType == .vertexAI,
               let gcloud = report.components.first(where: { $0.component == .gcloud }),
               !gcloud.isAvailable
            {
                return ("缺少 gcloud", AppColors.warning)
            }
            return ("gcloud 自動", AppColors.accent)

        case .localQwen:
            if viewModel.isSelectedModelCached {
                return ("模型就緒", AppColors.success)
            }
            if viewModel.isSelectedModelInDefaultHFCache {
                return ("可本機匯入", AppColors.accent)
            }
            return ("本機離線", AppColors.neutral)
        }
    }
}

struct BackendSelectionCard: View {
    let backend: ASRBackendType
    let isSelected: Bool
    let badge: (text: String, color: Color)
    let action: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button {
            action()
        } label: {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected ? AppColors.accent : .secondary)
                        .frame(width: 22, height: 22)

                    Spacer(minLength: 4)

                    StatusBadge(text: badge.text, color: badge.color)
                }

                Text(shortTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, minHeight: 98, alignment: .topLeading)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.card))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.card)
                    .stroke(cardBorder, lineWidth: isSelected ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.card))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(shortTitle)，\(badge.text)")
        .accessibilityHint(subtitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var shortTitle: String {
        switch backend {
        case .googleAIStudio:
            return "Google AI Studio"
        case .vertexAI:
            return "Vertex AI"
        case .localQwen:
            return "本機 Qwen"
        }
    }

    private var subtitle: String {
        switch backend {
        case .googleAIStudio:
            return "使用 API Key 雲端轉錄，免裝 gcloud。"
        case .vertexAI:
            return "使用 GCP 專案與 gcloud 憑證串流轉錄。"
        case .localQwen:
            return "錄音與模型留在這台 Mac，完全離線。"
        }
    }

    private var iconName: String {
        switch backend {
        case .googleAIStudio:
            return "sparkles"
        case .vertexAI:
            return "cloud.fill"
        case .localQwen:
            return CPUArchitecture.current == .x86_64 ? "cpu" : "apple.logo"
        }
    }

    private var cardBackground: Color {
        isSelected
            ? AppColors.accent.opacity(0.08)
            : AppColors.cardBackground
    }

    private var cardBorder: Color {
        isSelected
            ? AppColors.accent
            : AppColors.hairlineBorder(colorSchemeContrast: contrast)
    }
}

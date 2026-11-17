import SwiftUI

/// Legacy Phase-1 card wrapper preserving the exact pre-redesign appearance until Phase 2–3.
struct AppCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            }
    }
}

/// Shared modal sheet header used by Settings, Onboarding, and tool sheets.
struct SheetHeader<TrailingActions: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let trailingActions: TrailingActions

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailingActions: () -> TrailingActions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailingActions = trailingActions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(title)
                    .font(.title2.weight(.semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailingActions
        }
    }
}

/// Compact pill badge for component readiness, counts, and status tags.
struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, 3)
            .background(color.opacity(AppColors.statusTintOpacity), in: RoundedRectangle(cornerRadius: AppRadius.badge))
    }
}

/// Rounded status callout container for warnings, notices, and recoverable errors.
struct InlineCallout<Content: View>: View {
    let color: Color
    @ViewBuilder let content: Content

    init(color: Color, @ViewBuilder content: () -> Content) {
        self.color = color
        self.content = content()
    }

    var body: some View {
        content
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(AppColors.statusTintOpacity), in: RoundedRectangle(cornerRadius: AppRadius.row))
    }
}

/// Capsule chip button styling primitive for Composer settings.
struct SettingChip<LabelContent: View>: View {
    let isError: Bool
    let isDisabled: Bool
    let action: () -> Void
    @ViewBuilder let label: LabelContent

    @Environment(\.colorSchemeContrast) private var contrast

    init(
        isError: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> LabelContent
    ) {
        self.isError = isError
        self.isDisabled = isDisabled
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .font(AppTypography.chipLabel)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, 6)
                .background(
                    isError ? AppColors.danger.opacity(AppColors.statusTintOpacity) : AppColors.cardBackground,
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .stroke(
                            isError ? AppColors.danger : AppColors.hairlineBorder(colorSchemeContrast: contrast),
                            lineWidth: 1
                        )
                }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.6 : 1)
    }
}

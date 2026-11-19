import SwiftUI

/// Shared card surface container.
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
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.row)
                    .stroke(color.opacity(0.24), lineWidth: 1)
            }
    }
}

/// Capsule chip button styling primitive for Composer settings.
struct SettingChip<LabelContent: View>: View {
    let isActive: Bool
    let isError: Bool
    let isLocked: Bool
    let action: () -> Void
    @ViewBuilder let label: LabelContent

    @Environment(\.colorSchemeContrast) private var contrast

    init(
        isActive: Bool = false,
        isError: Bool = false,
        isLocked: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> LabelContent
    ) {
        self.isActive = isActive
        self.isError = isError
        self.isLocked = isLocked
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button {
            guard !isLocked else { return }
            action()
        } label: {
            label
                .font(AppTypography.chipLabel)
                .foregroundStyle(chipForeground)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, 6)
                .background(chipBackground, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(chipBorder, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .opacity(isLocked ? 0.68 : 1)
    }

    private var chipForeground: Color {
        if isError {
            return AppColors.danger
        }
        if isLocked {
            return .secondary
        }
        return .primary
    }

    private var chipBackground: Color {
        if isError {
            return AppColors.danger.opacity(AppColors.statusTintOpacity)
        }
        if isActive {
            return AppColors.accent.opacity(0.10)
        }
        return AppColors.windowBackground.opacity(0.75)
    }

    private var chipBorder: Color {
        if isError {
            return AppColors.danger
        }
        if isActive {
            return AppColors.accent.opacity(0.45)
        }
        return AppColors.hairlineBorder(colorSchemeContrast: contrast)
    }
}

/// Left-aligned wrapping flow layout for capsule chips and compact action buttons.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = AppSpacing.sm
    var verticalSpacing: CGFloat = AppSpacing.sm

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        guard !rows.isEmpty else { return .zero }

        var totalHeight: CGFloat = 0
        var widestRow: CGFloat = 0
        for (index, row) in rows.enumerated() {
            widestRow = max(widestRow, row.width)
            totalHeight += row.height
            if index > 0 {
                totalHeight += verticalSpacing
            }
        }
        let resolvedWidth = proposal.width ?? widestRow
        return CGSize(width: resolvedWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let itemY = y + (row.height - item.size.height) / 2
                item.subview.place(
                    at: CGPoint(x: x, y: itemY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct RowItem {
        let subview: LayoutSubview
        let size: CGSize
    }

    private struct Row {
        var items: [RowItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for subview in subviews {
            let natural = subview.sizeThatFits(.unspecified)
            let clampedWidth = maxWidth.isFinite ? min(natural.width, maxWidth) : natural.width
            let size = natural.width > clampedWidth
                ? subview.sizeThatFits(ProposedViewSize(width: clampedWidth, height: nil))
                : natural

            let nextWidth = current.items.isEmpty
                ? size.width
                : current.width + horizontalSpacing + size.width

            if !current.items.isEmpty && nextWidth > maxWidth {
                rows.append(current)
                current = Row(
                    items: [RowItem(subview: subview, size: size)],
                    width: size.width,
                    height: size.height
                )
            } else {
                current.items.append(RowItem(subview: subview, size: size))
                current.width = nextWidth
                current.height = max(current.height, size.height)
            }
        }

        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

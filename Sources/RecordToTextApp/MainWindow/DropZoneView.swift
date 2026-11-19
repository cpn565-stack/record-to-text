import SwiftUI

struct DropZoneView: View {
    let isTargeted: Bool
    let compact: Bool
    let showOnboardingSteps: Bool
    let chooseFiles: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if compact {
                compactContent
            } else {
                heroContent
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? AppSpacing.md : AppSpacing.xxl)
        .padding(.horizontal, compact ? AppSpacing.md : AppSpacing.lg)
        .background(
            isTargeted ? AppColors.accent.opacity(AppColors.statusTintOpacity) : AppColors.windowBackground.opacity(0.6),
            in: RoundedRectangle(cornerRadius: compact ? AppRadius.row : AppRadius.composer)
        )
        .overlay {
            RoundedRectangle(cornerRadius: compact ? AppRadius.row : AppRadius.composer)
                .strokeBorder(
                    isTargeted ? AppColors.accent : AppColors.hairlineBorder(colorSchemeContrast: contrast),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [7, 5])
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: compact ? AppRadius.row : AppRadius.composer))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(compact ? "加入更多錄音檔拖放區" : "錄音檔拖放區")
        .accessibilityValue("支援 M4A、MP3、WAV、AAC、FLAC")
        .accessibilityHint("可將錄音檔拖入視窗，或點選選擇錄音檔按鈕")
    }

    private var heroContent: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: isTargeted ? "arrow.down.doc.fill" : "waveform.badge.plus")
                .font(.system(size: 38, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isTargeted ? AppColors.accent : AppColors.accent.opacity(0.85))

            VStack(spacing: AppSpacing.xs) {
                Text(isTargeted ? "放開以加入佇列" : "將錄音拖入視窗")
                    .font(.title3.weight(.semibold))
                Text("M4A、MP3、WAV、AAC、FLAC")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("選擇錄音檔…", action: chooseFiles)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("選擇一或多個錄音檔加入佇列（⌘O）")

            if showOnboardingSteps {
                HStack(spacing: AppSpacing.sm) {
                    stepLabel(number: "1", text: "調整詞庫或背景")
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    stepLabel(number: "2", text: "拖入錄音")
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    stepLabel(number: "3", text: "點擊開始轉文字")
                }
                .padding(.top, AppSpacing.xs)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("使用步驟：一、調整詞庫或背景；二、拖入錄音；三、點擊開始轉文字")
            }
        }
    }

    private var compactContent: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: isTargeted ? "arrow.down.doc.fill" : "waveform.badge.plus")
                .font(.system(size: 19, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isTargeted ? AppColors.accent : AppColors.accent.opacity(0.85))

            VStack(alignment: .leading, spacing: 2) {
                Text(isTargeted ? "放開以加入佇列" : "拖入更多錄音以加入佇列")
                    .font(AppTypography.rowTitle)
                Text("M4A、MP3、WAV、AAC、FLAC")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: AppSpacing.sm)

            Button("選擇錄音檔…", action: chooseFiles)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("選擇更多錄音檔加入佇列（⌘O）")
        }
    }

    private func stepLabel(number: String, text: String) -> some View {
        HStack(spacing: 5) {
            Text(number)
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(AppColors.accent)
                .frame(width: 16, height: 16)
                .background(AppColors.accent.opacity(0.12), in: Circle())
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

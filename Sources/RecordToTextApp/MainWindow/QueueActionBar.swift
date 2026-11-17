import RecordToTextCore
import SwiftUI

/// Sticky bottom bar appearing only when queue work, active execution, or sleep notifications exist.
struct QueueActionBar: View {
    @ObservedObject var viewModel: AppViewModel

    @Environment(\.colorSchemeContrast) private var contrast

    static func shouldShow(for viewModel: AppViewModel) -> Bool {
        viewModel.hasQueuedJobs
            || viewModel.hasActiveJob
            || viewModel.queueSleep.countdownUntil != nil
            || viewModel.queueSleep.message != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(AppColors.hairlineBorder(colorSchemeContrast: contrast))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                if let until = viewModel.queueSleep.countdownUntil {
                    sleepCountdownBanner(until: until)
                } else if let sleepMessage = viewModel.queueSleep.message {
                    sleepMessageBanner(message: sleepMessage)
                }

                if viewModel.hasActiveJob {
                    activeBarContent
                } else if viewModel.hasQueuedJobs {
                    queuedBarContent
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(.horizontal, AppSpacing.xxl)
            .padding(.vertical, AppSpacing.md)
            .frame(maxWidth: .infinity)
        }
        .adaptiveGlassSurface(in: Rectangle())
    }

    // MARK: - Scenario A: Queued work waiting to start

    private var queuedBarContent: some View {
        let count = viewModel.queuedJobCount
        let engineLabel = JobModelDisplayHelper.currentEngineSummary(viewModel.settings)

        return HStack(alignment: .center, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text("等待 \(count) 筆 · 將以 \(engineLabel) 執行")
                    .font(AppTypography.rowMeta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                sleepCheckbox
            }

            Spacer(minLength: AppSpacing.md)

            HStack(spacing: AppSpacing.sm) {
                splitQueuedAction

                Button {
                    viewModel.startQueuedJobs()
                } label: {
                    Label("開始轉文字", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.isWaitingForStartup)
                .help("開始依序處理佇列中等待的錄音（⌘↩）")
            }
            .fixedSize()
        }
    }

    // MARK: - Scenario B: Active work in progress

    private var activeBarContent: some View {
        let queuedCount = viewModel.queuedJobCount

        return HStack(alignment: .center, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                if let active = viewModel.activeJob {
                    Text(
                        queuedCount > 0
                            ? "轉錄進行中：\(active.displayName)（另有 \(queuedCount) 筆等待）"
                            : "轉錄進行中：\(active.displayName)"
                    )
                    .font(AppTypography.rowMeta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }

                sleepCheckbox
            }

            Spacer(minLength: AppSpacing.md)

            HStack(spacing: AppSpacing.sm) {
                if viewModel.hasSplittableQueuedJobs {
                    splitQueuedAction
                }

                Button(role: .destructive) {
                    viewModel.cancelCurrentJob()
                } label: {
                    Label("取消目前工作", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("停止目前進行中的轉錄工作（⌘.）")
            }
            .fixedSize()
        }
    }

    // MARK: - Scenario C: Sleep countdown & status

    private func sleepCountdownBanner(until: Date) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "moon.zzz.fill")
                .foregroundStyle(AppColors.warning)
            (Text("轉檔已全部成功，") + Text(until, style: .timer).monospacedDigit() + Text(" 後休眠"))
                .font(AppTypography.rowMeta.weight(.medium))
            Spacer()
            Button("取消休眠") {
                viewModel.setSleepAfterCompletion(false)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func sleepMessageBanner(message: String) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "moon.stars")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
            Button("關閉") {
                viewModel.setSleepAfterCompletion(false)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private var sleepCheckbox: some View {
        Toggle(
            "完成後讓電腦休眠",
            isOn: Binding(
                get: { viewModel.queueSleep.isEnabled },
                set: viewModel.setSleepAfterCompletion
            )
        )
        .toggleStyle(.checkbox)
        .font(.caption)
        .help("僅本次有效；佇列全部無缺口成功完成後自動休眠，若有失敗、缺口或暫停則不會休眠")
    }

    @ViewBuilder
    private var splitQueuedAction: some View {
        if let job = viewModel.splittableQueuedJobs.first,
           viewModel.splittableQueuedJobs.count == 1
        {
            Button {
                viewModel.splitQueuedAudioFileInHalf(job.id)
            } label: {
                Label("切分再依序轉", systemImage: "scissors")
            }
            .buttonStyle(.bordered)
            .controlSize(viewModel.hasActiveJob ? .regular : .large)
            .help("把已加入佇列的錄音切成前後兩段；第一段先處理，第二段排在後面")
        } else if viewModel.hasSplittableQueuedJobs {
            Menu {
                ForEach(viewModel.splittableQueuedJobs) { job in
                    Button {
                        viewModel.splitQueuedAudioFileInHalf(job.id)
                    } label: {
                        Label(job.displayName, systemImage: "scissors")
                    }
                }
            } label: {
                Label("切分再依序轉", systemImage: "scissors")
            }
            .buttonStyle(.bordered)
            .controlSize(viewModel.hasActiveJob ? .regular : .large)
            .help("選擇已加入佇列的錄音，切成前後兩段並依序處理")
        }
    }
}

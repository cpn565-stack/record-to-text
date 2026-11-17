import RecordToTextCore
import SwiftUI

/// Visual 4-step milestone stepper + progress bar + recovery callouts for an in-flight transcription job.
struct ActiveJobProgressView: View {
    let job: TranscriptionJob
    @ObservedObject var viewModel: AppViewModel

    @State private var trackedSegment: Int?
    @State private var currentSegmentStartedAt = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            StageStepperView(stage: job.stage)

            progressOrRecoveryBody
        }
        .onAppear(perform: rememberCurrentSegment)
        .onChange(of: job.progressUnit) { _, _ in
            rememberCurrentSegment()
        }
    }

    @ViewBuilder
    private var progressOrRecoveryBody: some View {
        if let recovery = job.serviceRecovery,
           recovery.state == .coolingDown || recovery.state == .retrying
        {
            serviceRecoveryCallout(recovery)
        } else if let recovery = job.networkRecovery,
                  recovery.state == .waiting || recovery.state == .retrying
        {
            networkRecoveryCallout(recovery)
        } else if job.snapshot.backendType != .localQwen,
                  let segmentProgress = CloudSegmentProgressState(unit: job.progressUnit)
        {
            cloudSegmentProgress(segmentProgress)
        } else if let current = job.progressCurrent,
                  let total = job.progressTotal,
                  total > 0
        {
            ProgressView(value: min(current, total), total: total) {
                Text(progressLabel(current: current, total: total, unit: job.progressUnit))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: AppSpacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text(job.stage.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("目前階段：\(job.stage.displayName)")
        }
    }

    private func serviceRecoveryCallout(_ recovery: CloudServiceRecovery) -> some View {
        InlineCallout(color: AppColors.warning) {
            HStack(alignment: .top, spacing: AppSpacing.sm) {
                Image(systemName: recovery.state == .coolingDown ? "pause.circle.fill" : "arrow.clockwise.circle.fill")
                    .foregroundStyle(AppColors.warning)

                VStack(alignment: .leading, spacing: 3) {
                    Text(recovery.message)
                        .font(.caption.weight(.medium))
                    if let retryAt = recovery.nextRetryAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = max(0, Int(ceil(retryAt.timeIntervalSince(context.date))))
                            Text("約 \(remaining) 秒後再嘗試 · 已發送 \(recovery.attempts)／4 次")
                                .font(AppTypography.numericCaption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func networkRecoveryCallout(_ recovery: CloudNetworkRecovery) -> some View {
        InlineCallout(color: AppColors.warning) {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                Image(systemName: recovery.state == .waiting ? "wifi.exclamationmark" : "arrow.clockwise.circle.fill")
                    .foregroundStyle(AppColors.warning)

                VStack(alignment: .leading, spacing: 3) {
                    Text(recovery.message)
                        .font(.caption.weight(.medium))
                    if recovery.resultUnknown {
                        Text("前次請求的結果未知；重送可能產生重複費用。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let retryAt = recovery.nextRetryAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = max(0, Int(ceil(retryAt.timeIntervalSince(context.date))))
                            Text("約 \(remaining) 秒後重試")
                                .font(AppTypography.numericCaption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: AppSpacing.sm)

                if recovery.state == .waiting, job.id == viewModel.activeJobID {
                    Button("立刻重試") {
                        viewModel.retryNetworkImmediately(job.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!viewModel.canRetryNetworkImmediately(job.id))
                    .help("跳過目前的網路等待倒數，重新嘗試目前片段")
                }
            }
        }
    }

    private func cloudSegmentProgress(_ progress: CloudSegmentProgressState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            BreathingProgressBar(
                completedSegments: progress.completedSegments,
                totalSegments: progress.totalSegments,
                currentSegmentStartedAt: currentSegmentStartedAt,
                estimatedSegmentSeconds: estimatedSegmentSeconds,
                isCurrentSegmentInFlight: progress.phase == .preparing || progress.phase == .waiting
            )

            HStack(spacing: 6) {
                Text(cloudSegmentProgressLabel(progress))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if progress.phase == .waiting {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let segSeconds = max(0, Int(context.date.timeIntervalSince(currentSegmentStartedAt)))
                        Text("· 本段已耗時 \(segSeconds) 秒")
                            .font(AppTypography.numericCaption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cloudSegmentProgressLabel(progress))
    }

    private func cloudSegmentProgressLabel(_ progress: CloudSegmentProgressState) -> String {
        let completed = "已完成 \(progress.completedSegments)／\(progress.totalSegments) 段"
        switch progress.phase {
        case .preparing:
            return "正在準備第 \(progress.currentSegment)／\(progress.totalSegments) 段 · \(completed)"
        case .waiting:
            return "Gemini 轉錄中 · 第 \(progress.currentSegment)／\(progress.totalSegments) 段 · \(completed)"
        case .completed:
            return "Gemini \(completed)"
        case .postProcessing:
            return "所有分段已完成 · \(job.stage.displayName) · \(completed)"
        }
    }

    private var estimatedSegmentSeconds: TimeInterval {
        let latencies = job.resolvedCloudSegmentMetadata.compactMap(\.latencySeconds)
            .filter { $0 > 1 }
        if let median = Self.median(latencies) {
            return max(median, 20)
        }
        return 90
    }

    private func rememberCurrentSegment() {
        let segment = CloudSegmentProgressState(unit: job.progressUnit)?.currentSegment
        guard segment != trackedSegment else {
            return
        }
        trackedSegment = segment
        currentSegmentStartedAt = Date()
    }

    private func progressLabel(current: Double, total: Double, unit: String?) -> String {
        let rawUnit = unit ?? ""
        if rawUnit == "percent" || rawUnit.hasPrefix("percent|") {
            let percent = Int(min(max(current, 0), total).rounded())
            let parts = rawUnit.split(separator: "|", omittingEmptySubsequences: false)
            if parts.count == 3, let segment = Int(parts[1]), let count = Int(parts[2]) {
                return "整體 \(percent)% · 第 \(segment)／\(count) 段"
            }
            return "整體 \(percent)%"
        }
        if rawUnit == "segments" {
            return "第 \(Int(current.rounded()))／\(Int(total.rounded())) 段"
        }
        if rawUnit.isEmpty {
            return "\(Int(current.rounded())) / \(Int(total.rounded()))"
        }
        return "\(Int(current.rounded())) / \(Int(total.rounded())) \(rawUnit)"
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

/// Maps granular `TranscriptionStage` states into 4 user-comprehensible milestones.
struct StageStepperView: View {
    let stage: TranscriptionStage

    private static let titles = ["準備音訊", "模型轉錄", "繁體校正", "寫入檔案"]

    private var activeIndex: Int {
        switch stage {
        case .queued, .validating, .preparingRuntime, .downloadingModel, .convertingAudio, .loadingModel:
            return 0
        case .transcribing:
            return 1
        case .convertingTraditionalChinese:
            return 2
        case .writingOutput:
            return 3
        case .completed:
            return 4
        case .failed, .cancelled, .interrupted:
            return 0
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<Self.titles.count, id: \.self) { index in
                HStack(spacing: 4) {
                    Image(systemName: symbolName(for: index))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(symbolColor(for: index))

                    Text(Self.titles[index])
                        .font(.caption.weight(index == activeIndex ? .semibold : .regular))
                        .foregroundStyle(labelColor(for: index))
                        .lineLimit(1)
                }

                if index < Self.titles.count - 1 {
                    Rectangle()
                        .fill(
                            index < activeIndex
                                ? AppColors.success.opacity(0.45)
                                : Color(nsColor: .separatorColor).opacity(0.45)
                        )
                        .frame(maxWidth: 26, maxHeight: 1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("轉錄階段")
        .accessibilityValue(Self.titles[min(activeIndex, Self.titles.count - 1)])
    }

    private func symbolName(for index: Int) -> String {
        if index < activeIndex {
            return "checkmark.circle.fill"
        }
        if index == activeIndex {
            return "record.circle.fill"
        }
        return "circle"
    }

    private func symbolColor(for index: Int) -> Color {
        if index < activeIndex {
            return AppColors.success
        }
        if index == activeIndex {
            return AppColors.accent
        }
        return Color.secondary.opacity(0.45)
    }

    private func labelColor(for index: Int) -> Color {
        if index < activeIndex {
            return .secondary
        }
        if index == activeIndex {
            return .primary
        }
        return Color.secondary.opacity(0.55)
    }
}

struct BreathingProgressBar: View {
    let completedSegments: Int
    let totalSegments: Int
    let currentSegmentStartedAt: Date
    let estimatedSegmentSeconds: TimeInterval
    let isCurrentSegmentInFlight: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : 0.35)) { context in
            GeometryReader { proxy in
                let fraction = displayedFraction(at: context.date)
                let activeWidth = max(min(proxy.size.width * fraction, proxy.size.width), fraction > 0 ? 6 : 0)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    AppColors.accent.opacity(0.98),
                                    AppColors.accent.opacity(0.74)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .overlay {
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.clear,
                                            Color.cyan.opacity(0.38),
                                            Color.white.opacity(0.20)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .opacity(
                                    reduceMotion
                                        ? 0.24
                                        : (isBreathing ? 0.72 : 0.14)
                                )
                        }
                        .frame(width: activeWidth)
                }
            }
        }
        .frame(height: 6)
        .onAppear {
            updateBreathingAnimation(reduceMotion: reduceMotion)
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            updateBreathingAnimation(reduceMotion: shouldReduceMotion)
        }
        .accessibilityHidden(true)
    }

    private func updateBreathingAnimation(reduceMotion: Bool) {
        if reduceMotion {
            isBreathing = false
        } else {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                isBreathing = true
            }
        }
    }

    private func displayedFraction(at now: Date) -> Double {
        let total = Double(max(totalSegments, 1))
        let completed = min(max(Double(completedSegments) / total, 0), 1)
        guard isCurrentSegmentInFlight, completed < 1 else {
            return completed
        }
        let estimate = max(estimatedSegmentSeconds, 20)
        let elapsed = max(now.timeIntervalSince(currentSegmentStartedAt), 0)
        let slot = min(0.90, elapsed / estimate)
        return min(completed + slot / total, 1)
    }
}

struct CloudSegmentProgressState {
    enum Phase {
        case preparing
        case waiting
        case completed
        case postProcessing
    }

    let currentSegment: Int
    let completedSegments: Int
    let totalSegments: Int
    let phase: Phase

    init?(unit: String?) {
        let parts = (unit ?? "").split(
            separator: "|",
            omittingEmptySubsequences: false
        )
        guard parts.count == 3,
              let segment = Int(parts[1]),
              let total = Int(parts[2]),
              total > 0,
              segment >= 1,
              segment <= total
        else {
            return nil
        }

        switch parts[0] {
        case "preparing":
            phase = .preparing
            completedSegments = segment - 1
        case "waiting":
            phase = .waiting
            completedSegments = segment - 1
        case "percent":
            phase = .completed
            completedSegments = segment
        case "postprocessing":
            phase = .postProcessing
            completedSegments = total
        default:
            return nil
        }
        currentSegment = segment
        totalSegments = total
    }

    var percentage: Int {
        Int(
            (Double(completedSegments) / Double(totalSegments) * 100)
                .rounded()
        )
    }
}

struct JobElapsedView: View {
    let startedAt: Date?

    var body: some View {
        if let startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.formatter.string(from: max(context.date.timeIntervalSince(startedAt), 0)) ?? "")
                    .font(AppTypography.numericCaption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let formatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()
}

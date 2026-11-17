import SwiftUI

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
                        .fill(Color.primary.opacity(0.07))

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.98),
                                    Color.accentColor.opacity(0.74)
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
                                            Color.cyan.opacity(0.44),
                                            Color.white.opacity(0.18)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .opacity(
                                    reduceMotion
                                        ? 0.28
                                        : (isBreathing ? 0.72 : 0.14)
                                )
                        }
                        .frame(width: activeWidth)
                }
            }
        }
        .frame(height: 6)
        .onAppear {
            isBreathing = !reduceMotion
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            isBreathing = !shouldReduceMotion
        }
        .accessibilityHidden(true)
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
                    .font(.caption.monospacedDigit())
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

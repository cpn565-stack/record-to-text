import AppKit
import RecordToTextCore
import SwiftUI

struct JobLogExpansionState: Equatable, Sendable {
    private(set) var expandedIDs: Set<UUID> = []

    func isExpanded(_ id: UUID) -> Bool {
        expandedIDs.contains(id)
    }

    mutating func setExpanded(_ expanded: Bool, for id: UUID) {
        if expanded {
            expandedIDs.insert(id)
        } else {
            expandedIDs.remove(id)
        }
    }

    mutating func toggle(_ id: UUID) {
        setExpanded(!isExpanded(id), for: id)
    }

    mutating func prune(retaining ids: Set<UUID>) {
        expandedIDs.formIntersection(ids)
    }
}

struct ExpandableDebugTextPanel: View {
    let text: String
    let showJumpToLatest: Bool
    var developerJobID: UUID? = nil
    var developerBadges: [String] = []

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var copiedUUID = false

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 6) {
                if showJumpToLatest || developerJobID != nil || !developerBadges.isEmpty {
                    HStack(spacing: AppSpacing.sm) {
                        Text("完整執行日誌與診斷")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)

                        if let developerJobID {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(developerJobID.uuidString, forType: .string)
                                copiedUUID = true
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: copiedUUID ? "checkmark" : "doc.on.doc")
                                    Text(copiedUUID ? "已複製 UUID" : String(developerJobID.uuidString.prefix(8)))
                                        .font(AppTypography.monoDetail)
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("複製工作 UUID：\(developerJobID.uuidString)")
                        }

                        ForEach(developerBadges, id: \.self) { badge in
                            StatusBadge(text: badge, color: AppColors.neutral)
                        }

                        Spacer()

                        if showJumpToLatest {
                            Button("跳至最新") {
                                proxy.scrollTo("debug-panel-bottom", anchor: .bottom)
                            }
                            .buttonStyle(.link)
                            .font(.caption2)
                            .help("捲動到最新一則日誌")
                        }
                    }
                }

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(text)
                            .font(AppTypography.monoDetail)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Color.clear
                            .frame(height: 1)
                            .id("debug-panel-bottom")
                    }
                    .padding(AppSpacing.sm)
                }
                .frame(maxHeight: 220)
                .background(
                    AppColors.insetSurface,
                    in: RoundedRectangle(cornerRadius: AppRadius.row)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: AppRadius.row)
                        .stroke(AppColors.hairlineBorder(colorSchemeContrast: contrast), lineWidth: 1)
                }
            }
        }
    }
}

enum JobDebugClipboard {
    static func copy(_ summary: RecentJobSummary) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dump(summary), forType: .string)
    }

    static func dump(_ summary: RecentJobSummary) -> String {
        ["record-to-text 完成工作診斷", "版本：\(bundleVersionLabel)",
         "工作：\(summary.id.uuidString)",
         "狀態：\(summary.stage == .completed ? summary.resolvedOutputCompleteness.completionLabel : summary.stage.displayName)",
         summary.cloudDiagnostics?.debugSummary ?? "（舊工作未保存分段診斷）"].joined(separator: "\n")
    }

    static func copy(_ job: TranscriptionJob) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dump(job), forType: .string)
    }

    static func logToggleTitle(isExpanded: Bool, lineCount: Int, hasDiagnostics: Bool) -> String {
        if lineCount > 0 {
            return isExpanded ? "收合日誌" : "展開日誌（\(lineCount)）"
        }
        if hasDiagnostics {
            return isExpanded ? "收合診斷" : "展開診斷"
        }
        return ""
    }

    static func recentDiagnosticsToggleTitle(isExpanded: Bool) -> String {
        isExpanded ? "收合診斷" : "展開診斷"
    }

    static func expandedContent(for job: TranscriptionJob) -> String {
        var sections: [String] = []
        if !job.logLines.isEmpty {
            sections.append(job.logLines.joined(separator: "\n"))
        }
        if let diagnostics = job.cloudDiagnostics {
            let prefix = sections.isEmpty ? "" : "--- 分段診斷 ---\n"
            sections.append(prefix + diagnostics.debugSummary)
        }
        return sections.isEmpty ? "（無）" : sections.joined(separator: "\n\n")
    }

    static func expandedContent(for summary: RecentJobSummary) -> String? {
        summary.cloudDiagnostics?.debugSummary
    }

    static func statusSummary(from lines: [String]) -> String? {
        // Scan from the newest entry and stop after two visible messages.
        // Bound presentation only; dump(_:) retains the original log verbatim.
        var human: [String] = []
        for line in lines.reversed() {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !isDebugLine(line) else { continue }
            let prefix = String(line.prefix(240))
            human.append(prefix + (line.dropFirst(240).isEmpty ? "" : "…"))
            if human.count == 2 { break }
        }
        return human.isEmpty ? nil : human.reversed().joined(separator: "\n")
    }

    static func isDebugLine(_ line: String) -> Bool {
        let markers = [
            "HTTP ",
            "JSON ",
            "thinkingConfig",
            "實際請求",
            "response ",
            "responseId",
            "總 token",
            "thinking token",
            "promptTokenCount",
            "audioTokenCount",
            "promptFeedback",
            "rawBytes=",
            "modelVersion",
            "轉錄請求送出",
            "location global",
            "Gemini 回應無法形成逐字稿",
            "實際模型",
            "budget created",
            "budget root="
        ]
        return markers.contains { line.contains($0) }
    }

    static func dump(_ job: TranscriptionJob) -> String {
        var lines: [String] = [
            "record-to-text 除錯資訊",
            "版本：\(bundleVersionLabel)",
            "工作：\(job.id.uuidString)",
            "檔名：\(job.displayName)",
            "來源：\(job.sourcePath)",
            "後端：\(job.snapshot.backendType.displayName)",
            "模型：\(job.cloudModelSummary ?? job.snapshot.requestedModelID)",
            "狀態：\(job.stage == .completed ? job.resolvedOutputCompleteness.completionLabel : job.stage.displayName)"
        ]
        if let failure = job.failure {
            lines.append("失敗：\(failure.userMessage)")
            if !failure.technicalDetails.isEmpty {
                lines.append("技術細節：\(failure.technicalDetails)")
            }
        }
        let metadata = job.resolvedCloudSegmentMetadata
        if !metadata.isEmpty {
            let usage = CloudTranscriptionMetadataAggregator.totalUsage(metadata)
            let retries = CloudTranscriptionMetadataAggregator.totalRetryCount(metadata)
            if let total = usage?.totalTokenCount {
                lines.append("總 token：\(total)")
            }
            if let thoughts = usage?.thoughtsTokenCount {
                lines.append("thinking token：\(thoughts)")
            }
            if let cost = CloudTranscriptionMetadataAggregator.totalEstimatedCostUSD(metadata)
                ?? usage?.estimatedCostUSD(modelID: job.snapshot.requestedModelID)
            {
                lines.append("預估費用：\(CloudUsageMetadata.formatCostUSD(cost))")
            }
            if retries > 0 {
                lines.append("重試：\(retries)")
            }
        }
        if let diagnostics = job.cloudDiagnostics {
            lines.append("--- 分段診斷 ---")
            lines.append(diagnostics.debugSummary)
        }
        lines.append("--- 執行日誌 ---")
        if job.logLines.isEmpty {
            lines.append("（無）")
        } else {
            lines.append(contentsOf: job.logLines)
        }
        return lines.joined(separator: "\n")
    }

    static func developerBadges(for job: TranscriptionJob) -> [String] {
        let metadata = job.resolvedCloudSegmentMetadata
        guard !metadata.isEmpty else { return [] }
        var badges: [String] = []
        let retries = CloudTranscriptionMetadataAggregator.totalRetryCount(metadata)
        if retries > 0 {
            badges.append("重試 \(retries)")
        }
        if let cost = CloudTranscriptionMetadataAggregator.totalEstimatedCostUSD(metadata)
            ?? CloudTranscriptionMetadataAggregator.totalUsage(metadata)?.estimatedCostUSD(
                modelID: job.snapshot.requestedModelID
            )
        {
            badges.append("預估 \(CloudUsageMetadata.formatCostUSD(cost))")
        }
        return badges
    }

    static func developerBadges(for summary: RecentJobSummary) -> [String] {
        var badges: [String] = []
        if let retries = summary.cloudRetryCount, retries > 0 {
            badges.append("重試 \(retries)")
        }
        if let usage = summary.cloudUsage,
           let cost = usage.estimatedCostUSD(modelID: summary.effectiveModelIDs?.first ?? summary.modelID)
        {
            badges.append("預估 \(CloudUsageMetadata.formatCostUSD(cost))")
        }
        return badges
    }

    private static var bundleVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

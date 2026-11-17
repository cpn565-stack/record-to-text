import RecordToTextCore
import SwiftUI

/// Borderless sectioned job list placed directly on the window background:
/// 進行中 (Active) -> 等待中 (Queued) -> 已結束 (Finished, with collapsible older history).
struct JobListView: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var logExpansion: JobLogExpansionState
    @Binding var recentDiagnosticsExpansion: JobLogExpansionState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var previewURL: URL?
    @State private var isClearFinishedJobsPresented = false
    @State private var isOlderHistoryExpanded = false
    @State private var previousActiveJobID: UUID?
    @State private var recentlyCompletedHighlightID: UUID?
    @State private var highlightClearTask: Task<Void, Never>?

    private static let visibleFinishedLimit = 5

    private enum FinishedJobItem: Identifiable {
        case live(TranscriptionJob)
        case archived(RecentJobSummary)

        var id: UUID {
            switch self {
            case let .live(job):
                return job.id
            case let .archived(summary):
                return summary.id
            }
        }

        var sortDate: Date {
            switch self {
            case let .live(job):
                return job.completedAt ?? job.startedAt ?? job.createdAt
            case let .archived(summary):
                return summary.completedAt ?? summary.startedAt ?? .distantPast
            }
        }

        var isSeamlessCompleted: Bool {
            switch self {
            case let .live(job):
                return job.stage == .completed && job.resolvedOutputCompleteness != .hasGaps
            case let .archived(summary):
                return summary.stage == .completed && summary.resolvedOutputCompleteness != .hasGaps
            }
        }
    }

    var body: some View {
        let active = activeJobs
        let queued = queuedJobs
        let finished = finishedItems
        let primaryCompletedID = finished.first(where: \.isSeamlessCompleted)?.id

        VStack(alignment: .leading, spacing: AppSpacing.xl) {
            if !active.isEmpty {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text(active.count > 1 ? "進行中 · \(active.count)" : "進行中")
                        .font(AppTypography.sectionTitle)

                    LazyVStack(spacing: AppSpacing.sm) {
                        ForEach(active) { job in
                            JobRowView(
                                job: job,
                                viewModel: viewModel,
                                isLogExpanded: expansionBinding(in: $logExpansion, for: job.id),
                                onQuickLook: { previewURL = $0 }
                            )
                        }
                    }
                }
            }

            if !queued.isEmpty {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text("等待中 · \(queued.count)")
                        .font(AppTypography.sectionTitle)

                    LazyVStack(spacing: AppSpacing.sm) {
                        ForEach(queued) { job in
                            JobRowView(
                                job: job,
                                viewModel: viewModel,
                                isLogExpanded: expansionBinding(in: $logExpansion, for: job.id),
                                onQuickLook: { previewURL = $0 }
                            )
                        }
                    }
                }
            }

            if !finished.isEmpty {
                let primarySlice = Array(finished.prefix(Self.visibleFinishedLimit))
                let olderSlice = Array(finished.dropFirst(Self.visibleFinishedLimit))

                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("已結束 · \(finished.count)")
                            .font(AppTypography.sectionTitle)

                        Spacer()

                        if viewModel.hasFinishedJobs {
                            Button(role: .destructive) {
                                isClearFinishedJobsPresented = true
                            } label: {
                                Label("刪除全部已結束", systemImage: "trash")
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .foregroundStyle(AppColors.danger)
                            .help("刪除佇列與最近工作中所有已結束的工作（失敗／取消／完成等）")
                        }
                    }

                    LazyVStack(spacing: AppSpacing.sm) {
                        ForEach(primarySlice) { item in
                            finishedRow(for: item, primaryCompletedID: primaryCompletedID)
                        }
                    }

                    if !olderSlice.isEmpty {
                        DisclosureGroup(isExpanded: $isOlderHistoryExpanded) {
                            LazyVStack(spacing: AppSpacing.sm) {
                                ForEach(olderSlice) { item in
                                    finishedRow(for: item, primaryCompletedID: primaryCompletedID)
                                }
                            }
                            .padding(.top, AppSpacing.sm)
                        } label: {
                            Text("較早紀錄（\(olderSlice.count)）")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, AppSpacing.xs)
                    }
                }
            }
        }
        .transcriptQuickLookPreview($previewURL)
        .onAppear {
            previousActiveJobID = viewModel.activeJobID
        }
        .onChange(of: viewModel.activeJobID) { oldID, newID in
            previousActiveJobID = newID
            handlePotentialCompletionTransition(from: oldID, to: newID)
        }
        .onChange(of: Set(viewModel.jobs.map(\.id))) { _, liveIDs in
            logExpansion.prune(retaining: liveIDs)
        }
        .onChange(of: Set(viewModel.recentJobs.map(\.id))) { _, recentIDs in
            recentDiagnosticsExpansion.prune(retaining: recentIDs)
        }
        .onDisappear {
            highlightClearTask?.cancel()
        }
        .confirmationDialog(
            "刪除全部已結束的工作？",
            isPresented: $isClearFinishedJobsPresented,
            titleVisibility: .visible
        ) {
            Button("刪除全部已結束", role: .destructive) {
                viewModel.removeAllFinishedJobs()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("會從佇列與最近工作移除所有失敗、取消、中斷與已完成的項目。不會刪除原始錄音或已輸出的文字檔。進行中與排隊中的工作會保留。")
        }
    }

    @ViewBuilder
    private func finishedRow(
        for item: FinishedJobItem,
        primaryCompletedID: UUID?
    ) -> some View {
        switch item {
        case let .live(job):
            JobRowView(
                job: job,
                viewModel: viewModel,
                isLogExpanded: expansionBinding(in: $logExpansion, for: job.id),
                isPrimaryCompleted: job.id == primaryCompletedID,
                isCompletionHighlighted: job.id == recentlyCompletedHighlightID,
                onQuickLook: { previewURL = $0 }
            )
        case let .archived(summary):
            RecentJobRow(
                summary: summary,
                viewModel: viewModel,
                isDiagnosticsExpanded: expansionBinding(in: $recentDiagnosticsExpansion, for: summary.id),
                isPrimaryCompleted: summary.id == primaryCompletedID,
                onQuickLook: { previewURL = $0 }
            )
        }
    }

    // MARK: - Section Partitioning

    private func isActiveSectionJob(_ job: TranscriptionJob) -> Bool {
        job.id == viewModel.activeJobID
            || job.isCloudRecoveryPaused
            || (!job.stage.isTerminal && job.stage != .queued)
    }

    private var activeJobs: [TranscriptionJob] {
        viewModel.jobs.filter(isActiveSectionJob)
    }

    private var queuedJobs: [TranscriptionJob] {
        viewModel.jobs.filter { !isActiveSectionJob($0) && $0.stage == .queued }
    }

    private var finishedItems: [FinishedJobItem] {
        let liveIDs = Set(viewModel.jobs.map(\.id))
        let liveFinished = viewModel.jobs
            .filter { !isActiveSectionJob($0) && $0.stage.isTerminal }
            .map(FinishedJobItem.live)
        let archivedFinished = viewModel.recentJobs
            .filter { !liveIDs.contains($0.id) }
            .map(FinishedJobItem.archived)

        return (liveFinished + archivedFinished).sorted { lhs, rhs in
            if lhs.sortDate != rhs.sortDate {
                return lhs.sortDate > rhs.sortDate
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    // MARK: - Completion Highlight & Expansion Bindings

    private func handlePotentialCompletionTransition(from oldID: UUID?, to newID: UUID?) {
        guard let completedID = oldID,
              completedID != newID,
              let job = viewModel.jobs.first(where: { $0.id == completedID }),
              job.stage == .completed,
              job.resolvedOutputCompleteness != .hasGaps
        else {
            return
        }

        highlightClearTask?.cancel()
        if reduceMotion {
            recentlyCompletedHighlightID = completedID
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                recentlyCompletedHighlightID = completedID
            }
        }

        highlightClearTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            if reduceMotion {
                recentlyCompletedHighlightID = nil
            } else {
                withAnimation(.easeOut(duration: 0.45)) {
                    recentlyCompletedHighlightID = nil
                }
            }
        }
    }

    private func expansionBinding(
        in storage: Binding<JobLogExpansionState>,
        for id: UUID
    ) -> Binding<Bool> {
        Binding(
            get: { storage.wrappedValue.isExpanded(id) },
            set: { storage.wrappedValue.setExpanded($0, for: id) }
        )
    }
}

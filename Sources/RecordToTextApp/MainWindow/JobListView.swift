import RecordToTextCore
import SwiftUI

struct JobListView: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var logExpansion: JobLogExpansionState
    @Binding var recentDiagnosticsExpansion: JobLogExpansionState
    @State private var isClearFinishedJobsPresented = false

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("工作佇列", systemImage: "list.bullet.rectangle")
                        .font(.headline)
                    Spacer()

                    if viewModel.hasActiveJob {
                        Button(role: .destructive) {
                            viewModel.cancelCurrentJob()
                        } label: {
                            Label("取消目前工作", systemImage: "stop.fill")
                        }
                    }

                    if viewModel.hasFinishedJobs {
                        Button(role: .destructive) {
                            isClearFinishedJobsPresented = true
                        } label: {
                            Label("刪除全部已結束", systemImage: "trash")
                        }
                        .help("刪除佇列與最近工作中所有已結束的工作（失敗／取消／完成等）")
                    }
                }

                if viewModel.jobs.isEmpty {
                    VStack(spacing: 9) {
                        Image(systemName: "waveform")
                            .font(.system(size: 26))
                            .foregroundStyle(.tertiary)
                        Text("尚未加入錄音")
                            .font(.subheadline.weight(.medium))
                        Text("加入多個檔案後會依序處理，同時間只執行一個工作。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.jobs) { job in
                            JobRowView(
                                job: job,
                                viewModel: viewModel,
                                isLogExpanded: expansionBinding(in: $logExpansion, for: job.id)
                            )
                        }
                    }
                }

                if !archivedRecentJobs.isEmpty {
                    Divider()
                        .padding(.vertical, 2)

                    Text("最近工作")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    LazyVStack(spacing: 8) {
                        ForEach(archivedRecentJobs) { summary in
                            RecentJobRow(
                                summary: summary,
                                viewModel: viewModel,
                                isDiagnosticsExpanded: expansionBinding(in: $recentDiagnosticsExpansion, for: summary.id)
                            )
                        }
                    }
                }
            }
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

    private var archivedRecentJobs: [RecentJobSummary] {
        let liveIDs = Set(viewModel.jobs.map(\.id))
        return viewModel.recentJobs
            .filter { !liveIDs.contains($0.id) }
            .sorted {
                ($0.completedAt ?? $0.startedAt ?? .distantPast)
                    > ($1.completedAt ?? $1.startedAt ?? .distantPast)
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

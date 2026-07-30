import Foundation

public enum JobRetentionPolicy {
    public static func recentSummaries(
        _ summaries: [RecentJobSummary],
        limit: Int
    ) -> [RecentJobSummary] {
        let normalizedLimit = max(limit, 0)
        guard normalizedLimit > 0 else {
            return []
        }
        return summaries.enumerated()
            .sorted { lhs, rhs in
                let leftDate = summaryDate(lhs.element)
                let rightDate = summaryDate(rhs.element)
                if leftDate == rightDate {
                    return lhs.offset < rhs.offset
                }
                return leftDate < rightDate
            }
            .suffix(normalizedLimit)
            .map { $0.element }
    }

    public static func ledgerJobs(
        _ jobs: [TranscriptionJob],
        terminalHistoryLimit: Int,
        maximumLogLines: Int = 100
    ) -> [TranscriptionJob] {
        let durableIDs = Set(
            jobs.lazy
                .filter(isDurableAcrossRestarts)
                .map(\.id)
        )
        let retryableTerminal = jobs.filter {
            $0.stage.isTerminal
                && $0.stage != .completed
                && $0.stage != .interrupted
        }
        let terminalIDs = newestJobIDs(
            retryableTerminal,
            limit: terminalHistoryLimit
        )
        let retainedIDs = durableIDs.union(terminalIDs)
        let logLimit = max(maximumLogLines, 0)

        return jobs.compactMap { job in
            guard retainedIDs.contains(job.id) else {
                return nil
            }
            var retained = job
            if retained.logLines.count > logLimit {
                retained.logLines = Array(retained.logLines.suffix(logLimit))
            }
            return retained
        }
    }

    public static func inMemoryJobs(
        _ jobs: [TranscriptionJob],
        terminalHistoryLimit: Int
    ) -> [TranscriptionJob] {
        let durableIDs = Set(
            jobs.lazy
                .filter(isDurableAcrossRestarts)
                .map(\.id)
        )
        let terminalHistory = jobs.filter {
            $0.stage.isTerminal && $0.stage != .interrupted
        }
        let terminalIDs = newestJobIDs(
            terminalHistory,
            limit: terminalHistoryLimit
        )
        let retainedIDs = durableIDs.union(terminalIDs)
        return jobs.filter { retainedIDs.contains($0.id) }
    }

    public static func isDurableAcrossRestarts(
        _ job: TranscriptionJob
    ) -> Bool {
        !job.stage.isTerminal || job.stage == .interrupted
    }

    private static func newestJobIDs(
        _ jobs: [TranscriptionJob],
        limit: Int
    ) -> Set<UUID> {
        let normalizedLimit = max(limit, 0)
        guard normalizedLimit > 0 else {
            return []
        }
        let newest = jobs.enumerated()
            .sorted { lhs, rhs in
                let leftDate = jobDate(lhs.element)
                let rightDate = jobDate(rhs.element)
                if leftDate == rightDate {
                    return lhs.offset < rhs.offset
                }
                return leftDate < rightDate
            }
            .suffix(normalizedLimit)
        return Set(newest.map { $0.element.id })
    }

    private static func jobDate(_ job: TranscriptionJob) -> Date {
        job.completedAt ?? job.startedAt ?? job.createdAt
    }

    private static func summaryDate(_ summary: RecentJobSummary) -> Date {
        summary.completedAt ?? summary.startedAt ?? .distantPast
    }
}

import Foundation

// MARK: - History persistence

extension DownloadManager {
    /// Restores persisted records. Jobs that were active at last quit
    /// (queued/running/paused) become .interrupted — resumable via
    /// --continue on kept .part files. Terminal states load as-is.
    /// Records arrive newest-first, matching `jobs` ordering.
    func restoreHistory() {
        for record in historyStore.load() {
            let job = DownloadJob(record: record)
            switch job.state {
            case .queued, .running, .paused:
                job.state = .interrupted
            default:
                break
            }
            jobs.append(job)
            jobByID[job.id] = job
        }
    }

    /// Snapshots every job (any state) to history.json. Cheap: the
    /// store coalesces to ≤1 write per 500 ms on a background queue.
    func persistHistory() {
        historyStore.schedule(jobs.map(Self.record(for:)))
    }

    private static func record(for job: DownloadJob) -> HistoryRecord {
        HistoryRecord(
            id: job.id,
            videoURL: job.url,
            title: job.title,
            outputDirectory: job.outputDirectory,
            finalPath: job.finalPath,
            state: job.state.rawValue,
            progress: job.percent,
            totalSize: job.sizeText,
            createdAt: job.createdAt,
            finishedAt: job.finishedAt,
            errorText: job.errorText,
            quality: job.quality.rawValue,
            container: job.container.rawValue)
    }

    /// Forces pending history writes to disk. Used on quit and by tests.
    func flushHistory() {
        persistHistory()
        historyStore.flush()
    }
}

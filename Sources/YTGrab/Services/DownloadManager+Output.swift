import Foundation

// MARK: - Output handling
// Per-line stdout dispatch + exit handling. `classify` runs once per
// line; all branches are prefix/split lookups — O(len(line)).

extension DownloadManager {
    func job(withID id: UUID) -> DownloadJob? {
        jobByID[id]
    }

    func handleStdout(jobID: UUID, line: String) {
        guard let job = job(withID: jobID), contexts[jobID] != nil else {
            return
        }
        let kind = ProgressParser.classify(line)
        switch kind {
        case .progress(let update):
            handleTemplateProgress(jobID: jobID, job: job, update: update)
        case .streamPercent(let percent):
            // Once-per-stream summary line — bypasses the 5/s throttle.
            job.phase = .downloading
            applyStreamPercent(jobID: jobID, job: job, percent: percent)
        case .alreadyDownloaded:
            applyStreamPercent(jobID: jobID, job: job, percent: 100)
        case .filepath(let path):
            contexts[jobID]?.finalPath = path
        case .ignored:
            break
        default:
            handlePhaseLine(jobID: jobID, job: job, kind: kind)
        }
    }

    /// Phase-only kinds: preparing / fetching / destination / merge.
    private func handlePhaseLine(
        jobID: UUID, job: DownloadJob, kind: ParsedLineKind
    ) {
        switch kind {
        case .destination(let path):
            job.phase = .downloading
            if contexts[jobID]?.destinations.contains(path) == false {
                contexts[jobID]?.destinations.append(path)
            }
        case .preparing(let detail):
            job.phase = .preparing
            if let detail { job.phaseDetail = detail }
        case .fetchingFormats(let expected):
            job.phase = .fetching
            if let expected { contexts[jobID]?.expectedStreams = expected }
        case .merging, .postprocess:
            job.phase = .processing
            job.phaseDetail = kind == .merging ? "Merging…" : nil
        default:
            break
        }
    }

    /// Throttled application of `a|b|c|d` template updates — at most
    /// ~5 UI publishes/s per job, except the 100% line which always
    /// lands so the bar completes.
    private func handleTemplateProgress(
        jobID: UUID, job: DownloadJob, update: ProgressUpdate
    ) {
        job.phase = .downloading
        job.phaseDetail = nil
        let now = Date()
        let isFinal = (update.percent ?? 0) >= 100
        let lastApplied =
            contexts[jobID]?.lastProgressAppliedAt ?? .distantPast
        guard
            isFinal
                || now.timeIntervalSince(lastApplied) >= progressThrottle
        else { return }
        contexts[jobID]?.lastProgressAppliedAt = now
        if let percent = update.percent {
            applyStreamPercent(jobID: jobID, job: job, percent: percent)
        }
        if let speed = update.speed { job.speedText = speed }
        if let eta = update.eta { job.etaText = "ETA \(eta)" }
        if let total = update.total { job.sizeText = "of \(total)" }
        persistHistory()
    }

    /// Maps a per-stream percent onto overall job percent. With K > 1
    /// streams (from destinations seen and/or the [info] format(s) seed),
    /// overall = mean of per-stream percents — e.g. stream 1 done +
    /// stream 2 at 50% over K=2 → 75%. O(K), K ≤ 8 in practice.
    private func applyStreamPercent(
        jobID: UUID, job: DownloadJob, percent: Double
    ) {
        let streamIndex =
            max(0, (contexts[jobID]?.destinations.count ?? 1) - 1)
        contexts[jobID]?.streamPercents[streamIndex] = percent
        let streamCount = max(
            contexts[jobID]?.expectedStreams ?? 0,
            contexts[jobID]?.destinations.count ?? 0)
        guard streamCount > 1 else {
            job.percent = percent
            job.streamText = ""
            return
        }
        var sum = 0.0
        for index in 0..<streamCount {
            sum += min(contexts[jobID]?.streamPercents[index] ?? 0, 100)
        }
        job.percent = sum / Double(streamCount)
        job.streamText =
            "stream \(min(streamIndex + 1, streamCount))/\(streamCount)"
    }

    func handleStderr(jobID: UUID, line: String) {
        guard contexts[jobID] != nil else { return }
        if !line.isEmpty {
            contexts[jobID]?.stderrLastLine = line
        }
    }

    func handleExit(jobID: UUID, exit: ProcessExit) {
        let ctx = contexts[jobID]
        guard let job = job(withID: jobID) else {
            contexts[jobID] = nil
            return
        }
        job.phase = nil
        if ctx?.removeRequested == true {
            return  // remove() already cleaned up
        }
        if ctx?.stopRequested == true {
            job.state = .stopped
        } else if exit.succeeded {
            job.state = .done
            job.percent = 100
            job.speedText = ""
            job.etaText = ""
            job.streamText = ""
            job.finalPath = ctx?.finalPath ?? job.finalPath
        } else {
            job.state = .failed
            let last = ctx?.stderrLastLine ?? ""
            job.errorText = last.isEmpty ? Self.describe(exit) : last
        }
        job.finishedAt = Date()
        contexts[jobID]?.process = nil
        persistHistory()
        pump()
    }

    private static func describe(_ exit: ProcessExit) -> String {
        switch exit {
        case .exited(let code): return "yt-dlp exited with code \(code)"
        case .signaled(let sig): return "yt-dlp killed by signal \(sig)"
        }
    }
}

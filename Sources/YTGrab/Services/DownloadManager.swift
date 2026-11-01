import Foundation
import Observation

/// Per-process bookkeeping; internal so DownloadManager+Output.swift
/// and DownloadManager+History.swift extensions can share it.
struct JobContext {
    var process: (any SpawnedProcess)?
    var lastProgressAppliedAt = Date.distantPast
    var stderrLastLine = ""
    var finalPath: String?
    var stopRequested = false
    var removeRequested = false
    /// Distinct "[download] Destination:" paths seen, in order — one per
    /// output stream (e.g. .f397.mp4 video + .f251.webm audio).
    var destinations: [String] = []
    /// Stream count seeded from "[info] … Downloading N format(s)".
    var expectedStreams = 0
    /// Last percent per destination index, for multi-stream averaging.
    var streamPercents: [Int: Double] = [:]
}

@MainActor
@Observable
final class DownloadManager {
    /// Ordered newest-first for display; `jobByID` gives O(1) lookup on
    /// the per-line progress path instead of scanning the array.
    /// Newest-first means the *last* queued element is the oldest, so
    /// pump() picks `jobs.last(where: .queued)` to stay FIFO.
    /// Internal so the history extension (DownloadManager+History.swift)
    /// can append restored jobs; UI only reads.
    var jobs: [DownloadJob] = []
    var jobByID: [UUID: DownloadJob] = [:]
    var settings = DownloadSettings() {
        didSet { persistSettings() }
    }
    var selectedQuality: VideoQuality = .best
    var saveDirectory: String {
        didSet { defaults.set(saveDirectory, forKey: saveDirectoryKey) }
    }
    let missingTools: [String]

    /// Max simultaneous downloads. Default derives from the system
    /// (half the cores, clamped 1...8); persisted under "maxConcurrent"
    /// — the same key the UI's @AppStorage writes — and raising it
    /// immediately starts queued jobs via pump().
    var maxConcurrent: Int {
        get {
            guard
                let stored = defaults.object(forKey: maxConcurrentKey)
                    as? Int
            else { return Self.defaultMaxConcurrent }
            return Self.clampConcurrent(stored)
        }
        set {
            defaults.set(
                Self.clampConcurrent(newValue), forKey: maxConcurrentKey)
            pump()
        }
    }

    static var defaultMaxConcurrent: Int {
        clampConcurrent(ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    static func clampConcurrent(_ value: Int) -> Int {
        min(8, max(1, value))
    }

    private let spawner: any ProcessSpawner
    private let defaults: UserDefaults
    let historyStore: HistoryStore
    var contexts: [UUID: JobContext] = [:]

    private let saveDirectoryKey = "saveDirectory"
    private let subtitleLangsKey = "subtitleLangs"
    private let containerKey = "container"
    private let maxConcurrentKey = "maxConcurrent"
    /// Minimum interval between applied progress updates (~5 UI updates/s).
    let progressThrottle: TimeInterval = 0.2

    // Weak registries so the app delegate can reach live managers on quit.
    private static weak var current: DownloadManager?

    init(
        spawner: any ProcessSpawner = PosixSpawnSpawner(),
        defaults: UserDefaults = .standard,
        historyStore: HistoryStore = HistoryStore()
    ) {
        self.spawner = spawner
        self.defaults = defaults
        self.historyStore = historyStore
        var missing: [String] = []
        if Tooling.ytDLPPath == nil { missing.append("yt-dlp") }
        if Tooling.ffmpegPath == nil { missing.append("ffmpeg") }
        self.missingTools = missing

        let saved =
            defaults.string(forKey: saveDirectoryKey)
            ?? NSHomeDirectory() + "/Downloads"
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: saved, isDirectory: &isDir),
            isDir.boolValue
        {
            self.saveDirectory = saved
        } else {
            self.saveDirectory = NSHomeDirectory() + "/Downloads"
        }
        if let langs = defaults.string(forKey: subtitleLangsKey) {
            settings.subtitleLangs = langs
        }
        if let raw = defaults.string(forKey: containerKey),
            let container = VideoContainer(rawValue: raw)
        {
            settings.container = container
        }
        restoreHistory()
        Self.current = self
    }

    private func persistSettings() {
        defaults.set(settings.subtitleLangs, forKey: subtitleLangsKey)
        defaults.set(settings.container.rawValue, forKey: containerKey)
    }

    /// Non-nil when subtitles are enabled but the language list is invalid;
    /// the UI surfaces this inline and disables Download.
    var subtitleLangsError: String? {
        guard settings.downloadSubtitles else { return nil }
        return SubtitleLangsValidator.error(for: settings.subtitleLangs)
    }

    static func terminateCurrent() {
        current?.terminateAll()
    }

    var toolsAvailable: Bool { missingTools.isEmpty }

    // MARK: - Fetch info

    func fetchInfo(_ url: String) async throws -> VideoInfo {
        let validated = try URLValidator.validateVideoURL(url)
        guard let bin = Tooling.ytDLPPath else {
            throw ToolingError.binaryNotFound("yt-dlp")
        }
        let data = try await JSONRunner.run(
            spawner: spawner, executable: bin,
            arguments: YTDLPCommand.infoArguments(url: validated),
            environment: Tooling.childEnvironment)
        return try Self.parseInfo(data)
    }

    nonisolated static func parseInfo(_ data: Data) throws -> VideoInfo {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else {
            throw NSError(
                domain: "ytgrab", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Bad JSON"])
        }
        var heights = Set<Int>()
        for format in dict["formats"] as? [[String: Any]] ?? [] {
            if let height = format["height"] as? Int { heights.insert(height) }
        }
        return VideoInfo(
            title: dict["title"] as? String ?? "Untitled",
            id: dict["id"] as? String ?? "",
            heights: heights.sorted(),
            duration: dict["duration"] as? Double,
            uploader: dict["uploader"] as? String ?? dict["channel"] as? String)
    }

    // MARK: - Queue

    @discardableResult
    func enqueue(url: String, title: String, quality: VideoQuality) -> DownloadJob {
        let job = DownloadJob(
            title: title.isEmpty ? url : title, url: url, quality: quality)
        job.outputDirectory = saveDirectory
        job.container = settings.container
        jobs.insert(job, at: 0)  // newest-first
        jobByID[job.id] = job
        persistHistory()
        pump()
        return job
    }

    /// Fresh job for the same URL/quality — used by "Re-download" on
    /// finished history entries.
    @discardableResult
    func redownload(_ job: DownloadJob) -> DownloadJob {
        enqueue(url: job.url, title: job.title, quality: job.quality)
    }

    func pump() {
        let active = jobs.filter {
            $0.state == .running || $0.state == .paused
        }.count
        guard active < maxConcurrent,
            // jobs is newest-first: last .queued is the oldest → FIFO.
            let next = jobs.last(where: { $0.state == .queued })
        else { return }
        launch(next, freshStart: false)
        pump()
    }

    private func launch(_ job: DownloadJob, freshStart: Bool) {
        guard let bin = Tooling.ytDLPPath,
            let ffmpegDir = Tooling.ffmpegDirectory
        else {
            job.state = .failed
            job.errorText = "yt-dlp or ffmpeg not found"
            persistHistory()
            return
        }
        let spec = DownloadSpec(
            url: job.url, quality: job.quality,
            outputDirectory: job.outputDirectory, ffmpegDirectory: ffmpegDir,
            settings: settings, freshStart: freshStart)
        contexts[job.id] = JobContext()
        job.state = .running
        job.phase = .preparing
        job.phaseDetail = nil
        job.streamText = ""
        job.errorText = nil
        persistHistory()
        let jobID = job.id
        do {
            let proc = try spawner.spawn(
                executable: bin,
                arguments: YTDLPCommand.downloadArguments(spec: spec),
                environment: Tooling.childEnvironment,
                callbacks: SpawnCallbacks(
                    onStdoutLine: { [weak self] line in
                        Task { @MainActor in
                            self?.handleStdout(jobID: jobID, line: line)
                        }
                    },
                    onStderrLine: { [weak self] line in
                        Task { @MainActor in
                            self?.handleStderr(jobID: jobID, line: line)
                        }
                    },
                    onExit: { [weak self] exit in
                        Task { @MainActor in
                            self?.handleExit(jobID: jobID, exit: exit)
                        }
                    }))
            contexts[jobID]?.process = proc
        } catch {
            job.state = .failed
            job.errorText = String(describing: error)
            persistHistory()
        }
    }

    // MARK: - Per-job controls

    func pause(_ job: DownloadJob) {
        guard job.state == .running else { return }
        contexts[job.id]?.process?.signalGroup(SIGSTOP)
        job.state = .paused
        persistHistory()
    }

    func resumePaused(_ job: DownloadJob) {
        guard job.state == .paused else { return }
        contexts[job.id]?.process?.signalGroup(SIGCONT)
        job.state = .running
        persistHistory()
    }

    /// Terminate the process; partial .part files are kept so a later
    /// resume re-runs with --continue.
    func stop(_ job: DownloadJob) {
        if job.state == .queued {
            job.state = .stopped
            job.finishedAt = Date()
            persistHistory()
            return
        }
        guard job.state == .running || job.state == .paused else { return }
        contexts[job.id]?.stopRequested = true
        if let proc = contexts[job.id]?.process {
            proc.signalGroup(SIGCONT)
            proc.signalGroup(SIGKILL)
        }
    }

    /// Re-run with --continue; resumes from kept .part files.
    func resumeDownload(_ job: DownloadJob) {
        guard job.isResumable else { return }
        job.percent = 0
        job.phase = nil
        launch(job, freshStart: false)
    }

    /// Re-run from zero (--no-continue --force-overwrites).
    func restart(_ job: DownloadJob) {
        guard job.state != .running && job.state != .paused else { return }
        job.percent = 0
        job.phase = nil
        job.finalPath = nil
        launch(job, freshStart: true)
    }

    func remove(_ job: DownloadJob) {
        if job.state == .running || job.state == .paused {
            contexts[job.id]?.removeRequested = true
            if let proc = contexts[job.id]?.process {
                proc.signalGroup(SIGCONT)
                proc.signalGroup(SIGKILL)
            }
        }
        contexts[job.id] = nil
        jobByID[job.id] = nil
        jobs.removeAll { $0.id == job.id }
        persistHistory()
        pump()
    }

    // MARK: - Global controls

    func pauseAll() {
        for job in jobs where job.state == .running { pause(job) }
    }

    /// Removes terminal jobs (done/failed/stopped/cancelled); interrupted
    /// entries survive — they're cleared by clearHistory().
    func clearFinished() {
        let finished: Set<JobState> = [.done, .failed, .stopped, .cancelled]
        for job in jobs where finished.contains(job.state) {
            contexts[job.id] = nil
            jobByID[job.id] = nil
        }
        jobs.removeAll { finished.contains($0.state) }
        persistHistory()
    }

    /// Removes every non-active entry (anything not queued/running/
    /// paused), including interrupted and terminal history.
    func clearHistory() {
        let active: Set<JobState> = [.queued, .running, .paused]
        for job in jobs where !active.contains(job.state) {
            contexts[job.id] = nil
            jobByID[job.id] = nil
        }
        jobs.removeAll { !active.contains($0.state) }
        persistHistory()
    }

    func terminateAll() {
        for (_, ctx) in contexts {
            if let proc = ctx.process {
                proc.signalGroup(SIGCONT)
                proc.signalGroup(SIGKILL)
            }
        }
        contexts.removeAll()
        // Last durable snapshot before exit: in-flight jobs persist as
        // running/queued/paused and reload as .interrupted next launch.
        persistHistory()
        historyStore.flush()
    }

    // MARK: - Output handling
    // (line dispatch + exit handling live in DownloadManager+Output.swift)
}

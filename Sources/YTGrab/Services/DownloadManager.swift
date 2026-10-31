import Foundation
import Observation

private struct JobContext {
    var process: (any SpawnedProcess)?
    var lastProgressAppliedAt = Date.distantPast
    var stderrLastLine = ""
    var finalPath: String?
    var stopRequested = false
    var removeRequested = false
}

@MainActor
@Observable
final class DownloadManager {
    /// Ordered queue for display; `jobByID` gives O(1) lookup on the
    /// per-line progress path instead of scanning the array.
    private(set) var jobs: [DownloadJob] = []
    private var jobByID: [UUID: DownloadJob] = [:]
    var settings = DownloadSettings() {
        didSet { persistSettings() }
    }
    var selectedQuality: VideoQuality = .best
    var saveDirectory: String {
        didSet { defaults.set(saveDirectory, forKey: saveDirectoryKey) }
    }
    let missingTools: [String]
    let maxConcurrent = 2

    private let spawner: any ProcessSpawner
    private let defaults: UserDefaults
    private var contexts: [UUID: JobContext] = [:]

    private let saveDirectoryKey = "saveDirectory"
    private let subtitleLangsKey = "subtitleLangs"
    private let containerKey = "container"
    /// Minimum interval between applied progress updates (~5 UI updates/s).
    private let progressThrottle: TimeInterval = 0.2

    // Weak registries so the app delegate can reach live managers on quit.
    private static weak var current: DownloadManager?

    init(
        spawner: any ProcessSpawner = PosixSpawnSpawner(),
        defaults: UserDefaults = .standard
    ) {
        self.spawner = spawner
        self.defaults = defaults
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
        jobs.append(job)
        jobByID[job.id] = job
        pump()
        return job
    }

    private func pump() {
        let active = jobs.filter {
            $0.state == .running || $0.state == .paused
        }.count
        guard active < maxConcurrent,
            let next = jobs.first(where: { $0.state == .queued })
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
            return
        }
        let spec = DownloadSpec(
            url: job.url, quality: job.quality,
            outputDirectory: saveDirectory, ffmpegDirectory: ffmpegDir,
            settings: settings, freshStart: freshStart)
        contexts[job.id] = JobContext()
        job.state = .running
        job.phase = .preparing
        job.errorText = nil
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
        }
    }

    // MARK: - Per-job controls

    func pause(_ job: DownloadJob) {
        guard job.state == .running else { return }
        contexts[job.id]?.process?.signalGroup(SIGSTOP)
        job.state = .paused
    }

    func resumePaused(_ job: DownloadJob) {
        guard job.state == .paused else { return }
        contexts[job.id]?.process?.signalGroup(SIGCONT)
        job.state = .running
    }

    /// Terminate the process; partial .part files are kept so a later
    /// resume re-runs with --continue.
    func stop(_ job: DownloadJob) {
        if job.state == .queued {
            job.state = .stopped
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
        pump()
    }

    // MARK: - Global controls

    func pauseAll() {
        for job in jobs where job.state == .running { pause(job) }
    }

    func clearFinished() {
        let finished: Set<JobState> = [.done, .failed, .stopped, .cancelled]
        for job in jobs where finished.contains(job.state) {
            contexts[job.id] = nil
            jobByID[job.id] = nil
        }
        jobs.removeAll { finished.contains($0.state) }
    }

    func terminateAll() {
        for (_, ctx) in contexts {
            if let proc = ctx.process {
                proc.signalGroup(SIGCONT)
                proc.signalGroup(SIGKILL)
            }
        }
        contexts.removeAll()
    }

    // MARK: - Output handling

    private func job(withID id: UUID) -> DownloadJob? {
        jobByID[id]
    }

    private func handleStdout(jobID: UUID, line: String) {
        guard let job = job(withID: jobID), contexts[jobID] != nil else { return }
        if let update = ProgressParser.parse(line) {
            job.phase = .downloading
            let now = Date()
            let isFinal = (update.percent ?? 0) >= 100
            let lastApplied =
                contexts[jobID]?.lastProgressAppliedAt
                ?? .distantPast
            if isFinal
                || now.timeIntervalSince(lastApplied) >= progressThrottle
            {
                contexts[jobID]?.lastProgressAppliedAt = now
                if let percent = update.percent { job.percent = percent }
                if let speed = update.speed { job.speedText = speed }
                if let eta = update.eta { job.etaText = "ETA \(eta)" }
                if let total = update.total { job.sizeText = "of \(total)" }
            }
        } else if ProgressParser.isPostprocessLine(line) {
            job.phase = .processing
        } else if ProgressParser.isFilepathLine(line) {
            contexts[jobID]?.finalPath = line
        }
    }

    private func handleStderr(jobID: UUID, line: String) {
        guard contexts[jobID] != nil else { return }
        if !line.isEmpty {
            contexts[jobID]?.stderrLastLine = line
        }
    }

    private func handleExit(jobID: UUID, exit: ProcessExit) {
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
            job.finalPath = ctx?.finalPath ?? job.finalPath
        } else {
            job.state = .failed
            let last = ctx?.stderrLastLine ?? ""
            job.errorText = last.isEmpty ? Self.describe(exit) : last
        }
        contexts[jobID]?.process = nil
        pump()
    }

    private static func describe(_ exit: ProcessExit) -> String {
        switch exit {
        case .exited(let code): return "yt-dlp exited with code \(code)"
        case .signaled(let sig): return "yt-dlp killed by signal \(sig)"
        }
    }
}

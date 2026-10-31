import Foundation
import Testing

@testable import YTGrab

/// Real end-to-end tests driving the app's own code path
/// (DownloadManager + PosixSpawnSpawner + real yt-dlp).
/// Gated: only run with `YTGRAB_E2E=1` since they hit the network.
private let e2eEnabled = ProcessInfo.processInfo.environment["YTGRAB_E2E"] == "1"
private let testURL = "https://www.youtube.com/watch?v=R00Tgpx36l8"
private let badURL = "https://www.youtube.com/watch?v=AAAAAAAAAAA"

@MainActor
func poll(
    _ timeout: TimeInterval,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(200))
    }
    return condition()
}

func ffprobeStreams(_ path: String) -> (video: Bool, audio: Bool) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
    proc.arguments = [
        "-v", "error", "-show_entries", "stream=codec_type",
        "-of", "csv=p=0", path,
    ]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    let out = String(bytes: data, encoding: .utf8) ?? ""
    return (out.contains("video"), out.contains("audio"))
}

func partFiles(in dir: String) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: dir))?
        .filter { $0.hasSuffix(".part") } ?? []
}

@Suite(
    "E2E real yt-dlp", .serialized,
    .enabled(if: e2eEnabled, "set YTGRAB_E2E=1 to run network tests"))
@MainActor
struct IntegrationTests {
    @Test("720p download produces merged mp4 with audio+video")
    func download720() async throws {
        let dir = NSTemporaryDirectory() + "ytgrab-it-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let real = DownloadManager(
            spawner: PosixSpawnSpawner(),
            defaults: UserDefaults(suiteName: "ytgrab-it1-\(UUID().uuidString)") ?? .standard)
        real.saveDirectory = dir
        let job = real.enqueue(url: testURL, title: "t", quality: .h720)
        let finished = await poll(240) { job.state == .done || job.state == .failed }
        #expect(finished)
        #expect(job.state == .done, "state=\(job.state) err=\(job.errorText ?? "-")")
        guard let path = job.finalPath else {
            Issue.record("no finalPath")
            return
        }
        #expect(path.hasSuffix(".mp4"))
        #expect(FileManager.default.fileExists(atPath: path))
        let streams = ffprobeStreams(path)
        #expect(streams.video, "no video stream")
        #expect(streams.audio, "no audio stream")
    }

    @Test("audio-only m4a produces audio stream only")
    func audioM4A() async throws {
        let dir = NSTemporaryDirectory() + "ytgrab-it-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let real = DownloadManager(
            spawner: PosixSpawnSpawner(),
            defaults: UserDefaults(suiteName: "ytgrab-it2-\(UUID().uuidString)") ?? .standard)
        real.saveDirectory = dir
        let job = real.enqueue(url: testURL, title: "t", quality: .audioM4A)
        let finished = await poll(240) { job.state == .done || job.state == .failed }
        #expect(finished)
        #expect(job.state == .done, "err=\(job.errorText ?? "-")")
        guard let path = job.finalPath else {
            Issue.record("no finalPath")
            return
        }
        #expect(path.hasSuffix(".m4a"))
        let streams = ffprobeStreams(path)
        #expect(streams.audio)
        #expect(!streams.video)
    }

    @Test("SIGSTOP halts file growth; SIGCONT resumes it")
    func pauseResume() async throws {
        let dir = NSTemporaryDirectory() + "ytgrab-it-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let real = DownloadManager(
            spawner: PosixSpawnSpawner(),
            defaults: UserDefaults(suiteName: "ytgrab-it3-\(UUID().uuidString)") ?? .standard)
        real.saveDirectory = dir
        let job = real.enqueue(url: testURL, title: "t", quality: .h360)
        // Act the moment a .part appears: guaranteed in-flight state
        // (the file completes in ~3s at full speed, too fast for sleeps).
        let started = await poll(60) { !partFiles(in: dir).isEmpty }
        #expect(started)
        real.pause(job)
        #expect(job.state == .paused)
        try await Task.sleep(for: .seconds(1))
        let sizeBefore = dirSize(dir)
        try await Task.sleep(for: .seconds(3))
        let sizeAfter = dirSize(dir)
        #expect(
            sizeAfter == sizeBefore,
            "download progressed while SIGSTOPped (\(sizeBefore)->\(sizeAfter))")
        real.resumePaused(job)
        #expect(job.state == .running)
        let grew = await poll(20) {
            dirSize(dir) > sizeAfter
                || job.state == .done
        }
        #expect(grew, "download did not resume")
        real.terminateAll()
    }

    @Test("stop keeps .part files; resume completes the download")
    func stopResume() async throws {
        let dir = NSTemporaryDirectory() + "ytgrab-it-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let real = DownloadManager(
            spawner: PosixSpawnSpawner(),
            defaults: UserDefaults(suiteName: "ytgrab-it4-\(UUID().uuidString)") ?? .standard)
        real.saveDirectory = dir
        let job = real.enqueue(url: testURL, title: "t", quality: .h360)
        let started = await poll(60) { !partFiles(in: dir).isEmpty }
        #expect(started)
        real.stop(job)
        let stopped = await poll(20) { job.state == .stopped }
        #expect(stopped)
        #expect(!partFiles(in: dir).isEmpty, "no .part files kept for resume")
        real.resumeDownload(job)
        let finished = await poll(240) { job.state == .done || job.state == .failed }
        #expect(finished)
        #expect(job.state == .done, "err=\(job.errorText ?? "-")")
        #expect(partFiles(in: dir).isEmpty)
        #expect(FileManager.default.fileExists(atPath: job.finalPath ?? "/nope"))
    }

    @Test("restart from zero re-downloads (--no-continue)")
    func restart() async throws {
        let dir = NSTemporaryDirectory() + "ytgrab-it-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let real = DownloadManager(
            spawner: PosixSpawnSpawner(),
            defaults: UserDefaults(suiteName: "ytgrab-it5-\(UUID().uuidString)") ?? .standard)
        real.saveDirectory = dir
        let job = real.enqueue(url: testURL, title: "t", quality: .h360)
        let started = await poll(60) { job.percent > 0 }
        #expect(started)
        real.stop(job)
        _ = await poll(20) { job.state == .stopped }
        real.restart(job)
        let finished = await poll(240) { job.state == .done || job.state == .failed }
        #expect(finished)
        #expect(job.state == .done, "err=\(job.errorText ?? "-")")
    }

    @Test("unavailable video fails with readable error")
    func failingURL() async throws {
        let dir = NSTemporaryDirectory() + "ytgrab-it-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let real = DownloadManager(
            spawner: PosixSpawnSpawner(),
            defaults: UserDefaults(suiteName: "ytgrab-it6-\(UUID().uuidString)") ?? .standard)
        real.saveDirectory = dir
        let job = real.enqueue(url: badURL, title: "t", quality: .best)
        let finished = await poll(90) { job.state == .done || job.state == .failed }
        #expect(finished)
        #expect(job.state == .failed)
        #expect(!(job.errorText ?? "").isEmpty)
        print("failing-URL error surfaced:", job.errorText ?? "none")
    }

    @Test("browse search returns parseable entries")
    func browseSearch() async throws {
        let browse = BrowseManager(spawner: PosixSpawnSpawner())
        browse.run("india's got latent")
        let done = await poll(120) { !browse.isLoading }
        #expect(done)
        #expect(browse.errorText == nil, "err=\(browse.errorText ?? "-")")
        #expect(!browse.results.isEmpty)
        for entry in browse.results {
            #expect(URLValidator.isValidVideoID(entry.id))
            #expect(!entry.title.isEmpty)
        }
        print(
            "browse search: \(browse.results.count) entries,",
            "header:", browse.headerTitle ?? "-")
    }

    @Test("browse channel returns parseable entries")
    func browseChannel() async throws {
        let browse = BrowseManager(spawner: PosixSpawnSpawner())
        browse.run("https://www.youtube.com/@SamayRainaOfficial/videos")
        let done = await poll(120) { !browse.isLoading }
        #expect(done)
        #expect(browse.errorText == nil, "err=\(browse.errorText ?? "-")")
        #expect(!browse.results.isEmpty)
        for entry in browse.results {
            #expect(URLValidator.isValidVideoID(entry.id))
        }
        print(
            "browse channel: \(browse.results.count) entries,",
            "header:", browse.headerTitle ?? "-")
    }

    @Test("browse single video URL yields one entry")
    func browseVideoURL() async throws {
        let browse = BrowseManager(spawner: PosixSpawnSpawner())
        browse.run(testURL)
        let done = await poll(120) { !browse.isLoading }
        #expect(done)
        #expect(browse.errorText == nil, "err=\(browse.errorText ?? "-")")
        #expect(browse.results.count == 1)
        #expect(browse.results.first?.id == "R00Tgpx36l8")
    }
}

func dirSize(_ dir: String) -> Int64 {
    guard
        let files = try? FileManager.default
            .contentsOfDirectory(atPath: dir)
    else { return 0 }
    var total: Int64 = 0
    for file in files {
        let filePath = dir + "/" + file
        if let size = try? FileManager.default
            .attributesOfItem(atPath: filePath)[.size] as? Int64
        {
            total += size
        }
    }
    return total
}

struct ProbeResult {
    var format: String
    var video: Bool
    var audio: Bool
}

func ffprobeContainer(_ path: String) -> ProbeResult {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
    proc.arguments = [
        "-v", "error", "-show_entries",
        "format=format_name:stream=codec_type",
        "-of", "csv=p=0", path,
    ]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    let out = String(bytes: data, encoding: .utf8) ?? ""
    let lines = out.split(separator: "\n").map(String.init)
    let format =
        lines.first {
            $0.contains("mp4") || $0.contains("matroska")
                || $0.contains("webm")
        } ?? lines.first ?? ""
    return ProbeResult(format: format, video: out.contains("video"), audio: out.contains("audio"))
}

func listSubs(_ url: String) -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp")
    proc.arguments = [
        "--list-subs", "--skip-download", "--no-warnings",
        "--ignore-config", "--no-exec", "--", url,
    ]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return (String(bytes: data, encoding: .utf8) ?? "").contains("Available subtitles")
}

@Suite(
    "E2E containers and subtitles", .serialized, .timeLimit(.minutes(10)),
    .enabled(if: e2eEnabled, "set YTGRAB_E2E=1 to run network tests"))
@MainActor
struct ContainerE2ETests {
    @Test(
        "360p download in each container has correct format+streams",
        arguments: [
            (VideoContainer.mp4, "mp4"),
            (.mkv, "matroska"),
            (.webm, "webm"),
        ])
    func containers(container: VideoContainer, expected: String) async throws {
        let dir = NSTemporaryDirectory() + "ytgrab-ct-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let manager = DownloadManager(
            spawner: PosixSpawnSpawner(),
            defaults: UserDefaults(
                suiteName: "ytgrab-ct-\(UUID().uuidString)") ?? .standard)
        manager.saveDirectory = dir
        manager.settings.container = container
        let job = manager.enqueue(url: testURL, title: "t", quality: .h360)
        let finished = await poll(240) {
            job.state == .done || job.state == .failed
        }
        #expect(finished)
        #expect(job.state == .done, "err=\(job.errorText ?? "-")")
        guard let path = job.finalPath else {
            Issue.record("no finalPath")
            return
        }
        let probe = ffprobeContainer(path)
        #expect(
            probe.format.contains(expected),
            "container=\(probe.format) expected \(expected)")
        #expect(probe.video && probe.audio)
    }

    @Test("subtitles embed in mkv and mp4 when available")
    func subtitles() async throws {
        let url = try await videoWithSubs()
        for container in [VideoContainer.mp4, .mkv] {
            let dir = NSTemporaryDirectory() + "ytgrab-st-\(UUID().uuidString)"
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let manager = DownloadManager(
                spawner: PosixSpawnSpawner(),
                defaults: UserDefaults(
                    suiteName: "ytgrab-st-\(UUID().uuidString)") ?? .standard)
            manager.saveDirectory = dir
            manager.settings.container = container
            manager.settings.downloadSubtitles = true
            manager.settings.subtitleLangs = "en.*"
            let job = manager.enqueue(url: url, title: "t", quality: .h360)
            let finished = await poll(300) {
                job.state == .done || job.state == .failed
            }
            #expect(finished, "\(container): timed out")
            #expect(
                job.state == .done,
                "\(container): err=\(job.errorText ?? "-")")
            let probe = ffprobeContainer(job.finalPath ?? "")
            #expect(
                probe.format.contains(
                    container == .mp4 ? "mp4" : "matroska"))
        }
    }

    /// Finds a video with manual subtitles, preferring the test video.
    private func videoWithSubs() async throws -> String {
        if listSubs(testURL) { return testURL }
        // Probe a couple of well-known candidates; report which was used.
        let candidates = [
            "https://www.youtube.com/watch?v=aqz-KE-bpKQ",  // Big Buck Bunny
            "https://www.youtube.com/watch?v=YE7VzlLtp-4",
        ]
        for candidate in candidates where listSubs(candidate) {
            print("subtitle test video:", candidate)
            return candidate
        }
        throw NSError(
            domain: "ytgrab-test", code: -1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "no video with subtitles found"
            ])
    }
}

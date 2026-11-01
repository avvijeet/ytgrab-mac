import Foundation
import Testing

@testable import YTGrab

@Suite("History persistence")
@MainActor
struct HistoryTests {
    @Test("round-trip: finished job reloads as a done history entry")
    func roundTrip() async throws {
        let url = tempHistoryURL()
        let store = HistoryStore(fileURL: url)
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner, historyStore: store)
        manager.settings.container = .mkv
        let job = manager.enqueue(url: "u", title: "My Video", quality: .h720)
        spawner.lastChild?.stdout("/tmp/x [id].mkv")
        spawner.lastChild?.exit(.exited(0))
        try await flush()
        manager.flushHistory()

        let data = try Data(contentsOf: url)
        let records = try JSONDecoder().decode([HistoryRecord].self, from: data)
        #expect(records.count == 1)
        #expect(records[0].id == job.id)
        #expect(records[0].state == "done")
        #expect(records[0].finalPath == "/tmp/x [id].mkv")
        #expect(records[0].quality == "h720")
        #expect(records[0].container == "mkv")
        #expect(records[0].finishedAt != nil)

        // Relaunch: same store → entry restored with all fields.
        let relaunched = makeManager(spawner: spawner, historyStore: store)
        #expect(relaunched.jobs.count == 1)
        let restored = relaunched.jobs[0]
        #expect(restored.id == job.id)
        #expect(restored.state == .done)
        #expect(restored.title == "My Video")
        #expect(restored.finalPath == "/tmp/x [id].mkv")
        #expect(restored.container == .mkv)
        #expect(restored.createdAt == job.createdAt)
    }

    @Test("in-flight job at quit reloads as .interrupted and resumes")
    func interruptedRestore() async throws {
        let store = HistoryStore(fileURL: tempHistoryURL())
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner, historyStore: store)
        let job = manager.enqueue(url: "u", title: "t", quality: .best)
        #expect(job.state == .running)
        manager.flushHistory()  // simulates quit: running state on disk

        let relaunched = makeManager(spawner: spawner, historyStore: store)
        #expect(relaunched.jobs.count == 1)
        let restored = relaunched.jobs[0]
        #expect(restored.state == .interrupted)
        #expect(restored.isResumable)
        relaunched.resumeDownload(restored)
        #expect(restored.state == .running)
        let args = spawner.lastChild?.arguments ?? []
        #expect(args.contains("--continue"))
    }

    @Test("queued job at quit also reloads as .interrupted")
    func interruptedQueued() async throws {
        let store = HistoryStore(fileURL: tempHistoryURL())
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner, historyStore: store)
        _ = manager.enqueue(url: "u1", title: "t1", quality: .best)
        _ = manager.enqueue(url: "u2", title: "t2", quality: .best)
        let jobC = manager.enqueue(url: "u3", title: "t3", quality: .best)
        #expect(jobC.state == .queued)
        manager.flushHistory()

        let relaunched = makeManager(spawner: spawner, historyStore: store)
        #expect(relaunched.jobs.count == 3)
        #expect(relaunched.jobs[0].state == .interrupted)
        #expect(relaunched.jobs[0].id == jobC.id)  // newest first
    }

    @Test("corrupt history.json → empty start + .corrupt backup")
    func corruptFile() throws {
        let url = tempHistoryURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json {{{".utf8).write(to: url)
        let store = HistoryStore(fileURL: url)
        #expect(store.load() == [])
        #expect(
            FileManager.default.fileExists(
                atPath: url.appendingPathExtension("corrupt").path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("history capped at 500 entries, oldest trimmed")
    func capTrim() throws {
        let url = tempHistoryURL()
        let store = HistoryStore(fileURL: url)
        // 600 newest-first records: index 0 = newest.
        let records = (0..<600).map { index in
            HistoryRecord(
                id: UUID(), videoURL: "u\(index)", title: "t\(index)",
                outputDirectory: "/tmp", finalPath: nil, state: "done",
                progress: 100, totalSize: "", createdAt: Date(),
                finishedAt: Date(), errorText: nil,
                quality: "best", container: "mp4")
        }
        store.schedule(records)
        store.flush()
        let onDisk = store.load()
        #expect(onDisk.count == 500)
        // Newest (index 0) kept; oldest (index 599) trimmed.
        #expect(onDisk[0].title == "t0")
        #expect(onDisk.last?.title == "t499")
    }

    @Test("jobs list is newest-first; records preserve order on reload")
    func ordering() async throws {
        let store = HistoryStore(fileURL: tempHistoryURL())
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner, historyStore: store)
        let first = manager.enqueue(url: "u1", title: "first", quality: .best)
        let second = manager.enqueue(url: "u2", title: "second", quality: .best)
        #expect(manager.jobs[0].id == second.id)
        #expect(manager.jobs[1].id == first.id)
        manager.flushHistory()
        let relaunched = makeManager(spawner: spawner, historyStore: store)
        #expect(relaunched.jobs[0].title == "second")
        #expect(relaunched.jobs[1].title == "first")
    }

    @Test("search matches title, URL and finalPath case-insensitively")
    func searchFilter() {
        let job = DownloadJob(
            title: "INDIA'S GOT LATENT", url: "https://youtu.be/AbC",
            quality: .h360)
        job.finalPath = "/tmp/latent finale.mp4"
        #expect(job.matches("latent"))
        #expect(job.matches("YOUTU.BE/ABC"))
        #expect(job.matches("finale"))
        #expect(!job.matches("cricket"))
    }

    @Test("raising maxConcurrent immediately starts queued jobs")
    func stepperRaisesConcurrency() async throws {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner, maxConcurrent: 1)
        let jobA = manager.enqueue(url: "u1", title: "t1", quality: .best)
        let jobB = manager.enqueue(url: "u2", title: "t2", quality: .best)
        #expect(jobA.state == .running)
        #expect(jobB.state == .queued)
        #expect(spawner.spawned.count == 1)
        manager.maxConcurrent = 3
        #expect(jobB.state == .running)
        #expect(spawner.spawned.count == 2)
        // Lowering the limit doesn't kill running jobs.
        manager.maxConcurrent = 1
        #expect(jobA.state == .running && jobB.state == .running)
    }

    @Test("default maxConcurrent = clamped half of active cores")
    func defaultConcurrency() {
        let expected = min(
            8, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        #expect(DownloadManager.defaultMaxConcurrent == expected)
    }

    @Test("clearHistory removes non-active, keeps running/queued")
    func clearHistory() async throws {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        let jobA = manager.enqueue(url: "u1", title: "t1", quality: .best)
        let jobB = manager.enqueue(url: "u2", title: "t2", quality: .best)
        spawner.spawned[0].exit(.exited(0))
        try await flush()
        #expect(jobA.state == .done)
        #expect(jobB.state == .running)
        manager.clearHistory()
        #expect(manager.jobs.count == 1)
        #expect(manager.jobs[0].id == jobB.id)
        // Persisted too.
        manager.flushHistory()
        #expect(manager.historyStore.load().count == 1)
    }
}

@Suite("Live phases & multi-stream progress")
@MainActor
struct PhaseTests {
    @Test("[youtube]/[info]/[Merger] lines map to readable phases")
    func phases() async throws {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        let job = manager.enqueue(url: "u", title: "t", quality: .best)
        spawner.lastChild?.stdout(
            "[youtube] ce0XCrEvgI4: Downloading webpage")
        spawner.lastChild?.stdout(
            "[youtube] [jsc:deno] Solving JS challenges using deno")
        try await flush()
        #expect(job.phase == .preparing)
        #expect(job.statusLine == "Preparing · Solving JS challenges using deno")
        spawner.lastChild?.stdout(
            "[info] ce0XCrEvgI4: Downloading 1 format(s): 398+251")
        try await flush()
        #expect(job.phase == .fetching)
        #expect(job.statusLine == "Fetching formats")
        spawner.lastChild?.stdout("[Merger] Merging formats into \"/tmp/x.mp4\"")
        try await flush()
        #expect(job.phase == .processing)
        #expect(job.statusLine == "Merging…")
    }

    @Test("two-stream progress averages: stream1 done + stream2 50% → 75%")
    func multiStream() async throws {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        let job = manager.enqueue(url: "u", title: "t", quality: .best)
        spawner.lastChild?.stdout(
            "[info] ce0XCrEvgI4: Downloading 1 format(s): 398+251")
        spawner.lastChild?.stdout(
            "[download] Destination: /tmp/v.f398.mp4")
        // 100% isFinal → bypasses the throttle; expectedStreams=2 → 50%.
        spawner.lastChild?.stdout("100.0%| 2.00MiB/s|00:00| 357.15MiB")
        try await flush()
        #expect(job.percent == 50)
        #expect(job.streamText == "stream 1/2")
        spawner.lastChild?.stdout(
            "[download] Destination: /tmp/v.f251.webm")
        // Native per-stream summary bypasses the 5/s throttle.
        spawner.lastChild?.stdout(
            "[download] 50% of   10.00MiB in 00:00:10 at 1.00MiB/s")
        try await flush()
        #expect(job.percent == 75)
        #expect(job.streamText == "stream 2/2")
    }

    @Test("single-stream download ignores multi-stream math")
    func singleStream() async throws {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        let job = manager.enqueue(url: "u", title: "t", quality: .best)
        spawner.lastChild?.stdout("[download] Destination: /tmp/a.m4a")
        spawner.lastChild?.stdout(" 42.0%| 1.00MiB/s|00:10|  10.00MiB")
        try await flush()
        #expect(job.percent == 42)
        #expect(job.streamText.isEmpty)
    }
}

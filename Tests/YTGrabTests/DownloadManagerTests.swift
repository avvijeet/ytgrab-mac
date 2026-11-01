import Foundation
import Testing

@testable import YTGrab

/// Records spawn calls and replays scripted output/exit on demand.
final class FakeSpawner: ProcessSpawner, @unchecked Sendable {
    private let lock = NSLock()
    private var nextPID: pid_t = 9000
    private(set) var spawned: [FakeChild] = []

    final class FakeChild: SpawnedProcess, @unchecked Sendable {
        let pid: pid_t
        let executable: String
        let arguments: [String]
        let environment: [String: String]
        private let onStdout: @Sendable (String) -> Void
        private let onStderr: @Sendable (String) -> Void
        private let onExit: @Sendable (ProcessExit) -> Void
        private(set) var groupSignals: [Int32] = []

        init(
            pid: pid_t, executable: String, arguments: [String],
            environment: [String: String],
            onStdout: @escaping @Sendable (String) -> Void,
            onStderr: @escaping @Sendable (String) -> Void,
            onExit: @escaping @Sendable (ProcessExit) -> Void
        ) {
            self.pid = pid
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.onStdout = onStdout
            self.onStderr = onStderr
            self.onExit = onExit
        }

        func signalGroup(_ signal: Int32) { groupSignals.append(signal) }
        func signalProcess(_ signal: Int32) {}

        func stdout(_ line: String) { onStdout(line) }
        func stderr(_ line: String) { onStderr(line) }
        func exit(_ status: ProcessExit) { onExit(status) }
    }

    func spawn(
        executable: String, arguments: [String],
        environment: [String: String],
        callbacks: SpawnCallbacks
    ) throws -> any SpawnedProcess {
        lock.lock()
        defer { lock.unlock() }
        nextPID += 1
        let child = FakeChild(
            pid: nextPID, executable: executable, arguments: arguments,
            environment: environment,
            onStdout: callbacks.onStdoutLine,
            onStderr: callbacks.onStderrLine,
            onExit: callbacks.onExit)
        spawned.append(child)
        return child
    }

    var lastChild: FakeChild? {
        lock.lock()
        defer { lock.unlock() }
        return spawned.last
    }
}

/// Fresh history.json location under a unique temp dir.
func tempHistoryURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(
            "ytgrab-hist-\(UUID().uuidString)/history.json")
}

@MainActor
func makeManager(
    spawner: FakeSpawner,
    historyStore: HistoryStore = HistoryStore(fileURL: tempHistoryURL()),
    maxConcurrent: Int = 2
) -> DownloadManager {
    let suite = "ytgrab-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    let manager = DownloadManager(
        spawner: spawner, defaults: defaults, historyStore: historyStore)
    manager.saveDirectory = NSTemporaryDirectory()
    // Pin N so queued/running assertions don't depend on host core count.
    manager.maxConcurrent = maxConcurrent
    return manager
}

/// Lets enqueued @MainActor handler Tasks run.
func flush() async throws {
    await Task.yield()
    try await Task.sleep(for: .milliseconds(60))
}

func progressLine(_ pct: Double) -> String {
    "  \(pct)%| 1.00MiB/s|00:10|  10.00MiB"
}

@Suite("DownloadManager state machine", .serialized)
@MainActor
struct DownloadManagerTests {
    @Test("concurrency limit: 2 running, rest queued")
    func concurrencyLimit() async throws {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        let jobA = manager.enqueue(url: "u1", title: "t1", quality: .best)
        let jobB = manager.enqueue(url: "u2", title: "t2", quality: .best)
        let jobC = manager.enqueue(url: "u3", title: "t3", quality: .best)
        #expect(jobA.state == .running)
        #expect(jobB.state == .running)
        #expect(jobC.state == .queued)
        #expect(spawner.spawned.count == 2)
        // Finish first → third starts
        spawner.spawned[0].exit(.exited(0))
        try await flush()
        #expect(jobA.state == .done)
        #expect(jobC.state == .running)
    }

    @Test("pause sends SIGSTOP, resume sends SIGCONT")
    func pauseResume() async throws {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        let job = manager.enqueue(url: "u", title: "t", quality: .best)
        #expect(job.state == .running)
        manager.pause(job)
        #expect(job.state == .paused)
        #expect(spawner.lastChild?.groupSignals == [SIGSTOP])
        manager.resumePaused(job)
        #expect(job.state == .running)
        #expect(spawner.lastChild?.groupSignals == [SIGSTOP, SIGCONT])
    }

    @Test("stop kills group and lands in .stopped, kept resumable")
    func stopFlow() async throws {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        let job = manager.enqueue(url: "u", title: "t", quality: .best)
        manager.stop(job)
        #expect(spawner.lastChild?.groupSignals == [SIGCONT, SIGKILL])
        spawner.lastChild?.exit(.signaled(SIGKILL))
        try await flush()
        #expect(job.state == .stopped)
        #expect(job.isResumable)
        // Resume re-runs with --continue
        manager.resumeDownload(job)
        #expect(spawner.lastChild?.arguments.contains("--continue") == true)
        #expect(job.state == .running)
    }

    @Test("paused child is continued then killed on stop")
    func stopWhilePaused() async throws {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        let job = manager.enqueue(url: "u", title: "t", quality: .best)
        manager.pause(job)
        manager.stop(job)
        #expect(spawner.lastChild?.groupSignals == [SIGSTOP, SIGCONT, SIGKILL])
    }

    @Test("restart uses --no-continue --force-overwrites")
    func restart() async throws {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        let job = manager.enqueue(url: "u", title: "t", quality: .best)
        spawner.lastChild?.exit(.exited(0))
        try await flush()
        #expect(job.state == .done)
        manager.restart(job)
        let args = spawner.lastChild?.arguments ?? []
        #expect(args.contains("--no-continue"))
        #expect(args.contains("--force-overwrites"))
        #expect(job.state == .running)
    }

    @Test("failed exit surfaces last stderr line")
    func failure() async throws {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        let job = manager.enqueue(url: "u", title: "t", quality: .best)
        spawner.lastChild?.stderr("WARNING: something")
        spawner.lastChild?.stderr("ERROR: [youtube] x: Video unavailable")
        spawner.lastChild?.exit(.exited(1))
        try await flush()
        #expect(job.state == .failed)
        #expect(job.errorText == "ERROR: [youtube] x: Video unavailable")
        #expect(job.isResumable)
    }

    @Test("progress lines update job; postprocess switches phase; filepath captured")
    func progress() async throws {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        let job = manager.enqueue(url: "u", title: "t", quality: .best)
        spawner.lastChild?.stdout("  5.0%| 2.00MiB/s|00:30|  60.00MiB")
        try await flush()
        #expect(job.phase == .downloading)
        #expect(job.percent == 5.0)
        #expect(job.speedText == "2.00MiB/s")
        spawner.lastChild?.stdout("[Merger] Merging formats into \"/tmp/x.mp4\"")
        spawner.lastChild?.stdout("/tmp/x.mp4")
        try await flush()
        #expect(job.phase == .processing)
        spawner.lastChild?.exit(.exited(0))
        try await flush()
        #expect(job.state == .done)
        #expect(job.finalPath == "/tmp/x.mp4")
    }

    @Test("pauseAll pauses every running job; clearFinished removes terminal jobs")
    func global() async throws {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        let jobA = manager.enqueue(url: "u1", title: "t1", quality: .best)
        let jobB = manager.enqueue(url: "u2", title: "t2", quality: .best)
        manager.pauseAll()
        #expect(jobA.state == .paused && jobB.state == .paused)
        manager.stop(jobA)
        manager.stop(jobB)
        spawner.spawned[0].exit(.signaled(SIGKILL))
        spawner.spawned[1].exit(.signaled(SIGKILL))
        try await flush()
        manager.clearFinished()
        #expect(manager.jobs.isEmpty)
    }

    @Test("remove kills active child and drops job")
    func remove() async throws {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        let job = manager.enqueue(url: "u", title: "t", quality: .best)
        manager.remove(job)
        #expect(spawner.lastChild?.groupSignals == [SIGCONT, SIGKILL])
        #expect(manager.jobs.isEmpty)
    }

    @Test("terminateAll kills all children")
    func terminate() async throws {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        _ = manager.enqueue(url: "u1", title: "t1", quality: .best)
        _ = manager.enqueue(url: "u2", title: "t2", quality: .best)
        manager.terminateAll()
        #expect(spawner.spawned[0].groupSignals == [SIGCONT, SIGKILL])
        #expect(spawner.spawned[1].groupSignals == [SIGCONT, SIGKILL])
    }

    @Test("minimal environment passed to child")
    func environment() async throws {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        _ = manager.enqueue(url: "u", title: "t", quality: .best)
        let env = spawner.lastChild?.environment ?? [:]
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        #expect(env["LANG"] == "en_US.UTF-8")
        #expect(env["HOME"] != nil)
        #expect(env.count == 3)
    }

    @Test("parseInfo extracts title and heights")
    func parseInfo() throws {
        let json = Data(
            """
            {"id":"x","title":"T","uploader":"U","duration":12.0,
             "formats":[{"height":144},{"height":480},{"height":null},{}]}
            """.utf8)
        let info = try DownloadManager.parseInfo(json)
        #expect(info.title == "T")
        #expect(info.heights == [144, 480])
        #expect(info.uploader == "U")
    }
}

@Suite("Spawner exit delivery")
struct SpawnerExitTests {
    @Test("onExit fires when a grandchild holds the pipes open")
    func grandchildHoldsPipe() async throws {
        let spawner = PosixSpawnSpawner()
        let exited = LockedBox<ProcessExit?>(nil)
        // /bin/sh exits immediately; its `sleep 5` grandchild inherits the
        // stdout pipe, keeping it open past reap.
        let proc = try spawner.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 5 & exit 0"],
            environment: Tooling.childEnvironment,
            callbacks: SpawnCallbacks(
                onStdoutLine: { _ in },
                onStderrLine: { _ in },
                onExit: { exit in exited.withLock { $0 = exit } }))
        let deadline = Date().addingTimeInterval(3)
        while exited.withLock({ $0 }) == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = proc
        let exit = exited.withLock { $0 }
        #expect(
            exit != nil,
            "onExit never fired — grandchild held pipe open")
        #expect(exit == .exited(0))
    }
}

@Suite("Spawner line delivery")
struct SpawnerLineTests {
    @Test("final line delivered before onExit under output flood")
    func finalLineDelivered() async throws {
        let spawner = PosixSpawnSpawner()
        let lines = LockedBox<[String]>([])
        let errLines = LockedBox<[String]>([])
        let exited = LockedBox<ProcessExit?>(nil)
        // Lines then a final "filepath" line WITHOUT a trailing newline,
        // and a lingering grandchild keeps the pipe open past reap —
        // deterministically forces the grace-flush path (no EOF).
        let cmd = "printf 'line1\\nline2\\nFILEPATH:/tmp/x.mp4'; sleep 30 & exit 0"
        _ = try spawner.spawn(
            executable: "/bin/sh",
            arguments: ["-c", cmd],
            environment: Tooling.childEnvironment,
            callbacks: SpawnCallbacks(
                onStdoutLine: { line in
                    lines.withLock { $0.append(line) }
                },
                onStderrLine: { line in
                    errLines.withLock { $0.append(line) }
                },
                onExit: { exit in exited.withLock { $0 = exit } }))
        let deadline = Date().addingTimeInterval(10)
        while exited.withLock({ $0 }) == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(exited.withLock { $0 } != nil, "onExit never fired")
        let all = lines.withLock { $0 }
        #expect(
            all.contains("FILEPATH:/tmp/x.mp4"),
            "final unterminated line lost; got \(all.count) lines")
    }

    @Test("child executes under test host")
    func childRuns() async throws {
        try? FileManager.default.removeItem(atPath: "/tmp/spawnout.txt")
        let spawner = PosixSpawnSpawner()
        let exited = LockedBox<ProcessExit?>(nil)
        _ = try spawner.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'ran\n' > /tmp/spawnout.txt; exit 0"],
            environment: Tooling.childEnvironment,
            callbacks: SpawnCallbacks(
                onStdoutLine: { _ in }, onStderrLine: { _ in },
                onExit: { exit in exited.withLock { $0 = exit } }))
        let deadline = Date().addingTimeInterval(10)
        while exited.withLock({ $0 }) == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(exited.withLock { $0 } == .exited(0))
        let out = try? String(
            contentsOfFile: "/tmp/spawnout.txt",
            encoding: .utf8)
        #expect(out == "ran\n", "child wrote: \(out ?? "nil")")
    }

    @Test("lines delivered on EOF path")
    func eofLines() async throws {
        let spawner = PosixSpawnSpawner()
        let lines = LockedBox<[String]>([])
        let exited = LockedBox<ProcessExit?>(nil)
        _ = try spawner.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'aaa\nbbb\n'; exit 0"],
            environment: Tooling.childEnvironment,
            callbacks: SpawnCallbacks(
                onStdoutLine: { line in
                    lines.withLock { $0.append(line) }
                },
                onStderrLine: { _ in },
                onExit: { exit in exited.withLock { $0 = exit } }))
        let deadline = Date().addingTimeInterval(10)
        while exited.withLock({ $0 }) == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(exited.withLock { $0 } != nil)
        #expect(lines.withLock { $0 } == ["aaa", "bbb"])
    }
}

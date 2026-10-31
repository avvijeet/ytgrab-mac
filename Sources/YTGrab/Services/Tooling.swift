import Foundation

enum ToolingError: Error, Equatable, CustomStringConvertible {
    case binaryNotFound(String)
    case spawnFailed(Int32)

    var description: String {
        switch self {
        case .binaryNotFound(let name): return "\(name) not found"
        case .spawnFailed(let code): return "posix_spawn failed (errno \(code))"
        }
    }
}

enum Tooling {
    // Binaries are resolved ONLY from this fixed list. PATH is never searched.
    static let binarySearchPaths = ["/opt/homebrew/bin", "/usr/local/bin"]

    static func resolve(_ name: String) -> String? {
        for dir in binarySearchPaths {
            let candidate = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static var ytDLPPath: String? { resolve("yt-dlp") }
    static var ffmpegPath: String? { resolve("ffmpeg") }
    static var ffmpegDirectory: String? {
        ffmpegPath.map { ($0 as NSString).deletingLastPathComponent }
    }

    // Minimal, explicit child environment.
    static var childEnvironment: [String: String] {
        [
            "PATH": (binarySearchPaths + ["/usr/bin", "/bin"]).joined(separator: ":"),
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
        ]
    }
}

enum ProcessExit: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)

    var succeeded: Bool { self == .exited(0) }
}

protocol SpawnedProcess: Sendable {
    var pid: pid_t { get }
    /// Signal the whole process group (child is a group leader).
    func signalGroup(_ signal: Int32)
    /// Signal only the direct child process.
    func signalProcess(_ signal: Int32)
}

/// Output callbacks for a spawned process.
struct SpawnCallbacks: Sendable {
    var onStdoutLine: @Sendable (String) -> Void
    var onStderrLine: @Sendable (String) -> Void
    /// Fires exactly once, after the process is reaped AND both output
    /// pipes have reached EOF and been flushed.
    var onExit: @Sendable (ProcessExit) -> Void
}

protocol ProcessSpawner: Sendable {
    /// Spawn `executable` in its own process group with the given argv and
    /// environment. Output is delivered line-by-line on background queues.
    func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        callbacks: SpawnCallbacks
    ) throws -> any SpawnedProcess
}

/// Buffers arbitrary byte chunks and emits complete lines. Thread-safe.
final class LineAssembler: @unchecked Sendable {
    private var pending = [UInt8]()
    private let queue = DispatchQueue(label: "local.ytgrab.lines")
    private let onLine: @Sendable (String) -> Void
    var onClosed: @Sendable () -> Void

    init(
        onLine: @escaping @Sendable (String) -> Void,
        onClosed: @escaping @Sendable () -> Void = {}
    ) {
        self.onLine = onLine
        self.onClosed = onClosed
    }

    func append(_ data: Data) {
        queue.async {
            self.pending.append(contentsOf: data)
            // Array indices are always 0-based, so firstIndex and
            // removeFirst(count) cannot diverge the way Data slices can.
            while let newlineIdx = self.pending.firstIndex(of: 0x0A) {
                var line =
                    String(
                        bytes: self.pending[0..<newlineIdx],
                        encoding: .utf8) ?? ""
                if line.hasSuffix("\r") { line.removeLast() }
                self.pending.removeFirst(newlineIdx + 1)
                self.onLine(line)
            }
        }
    }

    func finish() {
        queue.async {
            if !self.pending.isEmpty {
                var line = String(bytes: self.pending, encoding: .utf8) ?? ""
                if line.hasSuffix("\r") { line.removeLast() }
                self.pending.removeAll()
                self.onLine(line)
            }
            self.onClosed()
        }
    }
}

/// A child spawned via posix_spawn in its own process group (pgid == pid),
/// so the entire tree (yt-dlp + ffmpeg children) can be signalled at once.
final class PosixSpawnedProcess: SpawnedProcess, @unchecked Sendable {
    let pid: pid_t

    init(pid: pid_t) { self.pid = pid }

    func signalGroup(_ signal: Int32) {
        // Negative pid targets the process group; the child is group leader.
        kill(-pid, signal)
    }

    func signalProcess(_ signal: Int32) {
        kill(pid, signal)
    }
}

final class PosixSpawnSpawner: ProcessSpawner {
    init() {}

    func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        callbacks: SpawnCallbacks
    ) throws -> any SpawnedProcess {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var devNullFD: Int32 = -1
        devNullFD = open("/dev/null", O_RDONLY)
        if devNullFD >= 0 {
            posix_spawn_file_actions_adddup2(&fileActions, devNullFD, STDIN_FILENO)
        }
        posix_spawn_file_actions_adddup2(
            &fileActions, stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(
            &fileActions, stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        // New process group so we can SIGSTOP/SIGCONT/SIGKILL the whole tree.
        // CLOEXEC_DEFAULT closes all unrelated inherited fds at exec.
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        posix_spawnattr_setflags(&attrs, flags)
        posix_spawnattr_setpgroup(&attrs, 0)

        let fullArgs = [executable] + arguments
        var cArgv: [UnsafeMutablePointer<CChar>?] =
            fullArgs.map { strdup($0) } + [nil]
        var cEnv: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cArgv.forEach { free($0) }
            cEnv.forEach { free($0) }
        }

        var pid = pid_t()
        let spawnError = cArgv.withUnsafeMutableBufferPointer { argvBuf in
            cEnv.withUnsafeMutableBufferPointer { envBuf in
                posix_spawn(
                    &pid, executable, &fileActions, &attrs,
                    argvBuf.baseAddress, envBuf.baseAddress)
            }
        }
        if devNullFD >= 0 { close(devNullFD) }
        guard spawnError == 0 else { throw ToolingError.spawnFailed(spawnError) }

        // Parent must close its copy of the write ends so EOF propagates.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let stdoutAssembler = LineAssembler(onLine: callbacks.onStdoutLine)
        let stderrAssembler = LineAssembler(onLine: callbacks.onStderrLine)
        let childPID = pid
        let state = ExitCoordinator(onExit: callbacks.onExit) {
            // SIGKILL any lingering grandchildren so reader threads reach
            // a real EOF and finish() flushes the complete final line.
            kill(-childPID, SIGKILL)
        }
        stdoutAssembler.onClosed = { state.pipeClosed() }
        stderrAssembler.onClosed = { state.pipeClosed() }
        attachReader(stdoutPipe, assembler: stdoutAssembler)
        attachReader(stderrPipe, assembler: stderrAssembler)
        reapAsync(pid: pid, coordinator: state)

        return PosixSpawnedProcess(pid: pid)
    }

    /// Dedicated blocking-read thread: reads until EOF (write end closed
    /// by every holder), feeding the assembler incrementally. Used instead
    /// of readabilityHandler, which does not fire under swiftpm test hosts.
    private func attachReader(_ pipe: Pipe, assembler: LineAssembler) {
        // The FileHandle must be retained by the reader thread: closing the
        // last reference invalidates the fd (EBADF). Pipe is released when
        // spawn() returns.
        let readHandle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            let readFD = readHandle.fileDescriptor
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(readFD, &chunk, chunk.count)
                if count <= 0 { break }
                assembler.append(Data(chunk[0..<count]))
            }
            try? readHandle.close()
            assembler.finish()
        }
    }

    private func reapAsync(pid: pid_t, coordinator: ExitCoordinator) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            let exit: ProcessExit
            if status & 0x7F == 0 {
                exit = .exited((status >> 8) & 0xFF)
            } else if status & 0x7F == 0x7F {
                exit = .exited(-1)  // WIFSTOPPED; not expected without WUNTRACED
            } else {
                exit = .signaled(status & 0x7F)
            }
            coordinator.processExited(exit)
        }
    }
}

/// Fires `onExit` after the process has been reaped and both pipes have
/// reached EOF — or, if grandchildren still hold the pipes open past a
/// short grace window after reap, as soon as that window elapses. The
/// grace bound guarantees exit delivery even when a lingering ffmpeg /
/// deno grandchild keeps a write end open.
private final class ExitCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var exit: ProcessExit?
    private var pipesClosed = 0
    private var fired = false
    private let onExit: @Sendable (ProcessExit) -> Void
    private let onGraceExpired: @Sendable () -> Void
    private let grace: DispatchTimeInterval = .milliseconds(500)
    private let hardCap: DispatchTimeInterval = .seconds(2)

    init(
        onExit: @escaping @Sendable (ProcessExit) -> Void,
        onGraceExpired: @escaping @Sendable () -> Void
    ) {
        self.onExit = onExit
        self.onGraceExpired = onGraceExpired
    }

    func processExited(_ exit: ProcessExit) {
        lock.lock()
        self.exit = exit
        maybeFire()
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            // Reap already happened; grandchildren still hold the pipes.
            // Kill them so readers reach a real EOF; the EOF finish()
            // delivers the buffered final line before onExit.
            self.onGraceExpired()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + hardCap) {
            // Unkillable stragglers (or a reader stuck elsewhere): force
            // the gate after the hard cap so onExit always fires.
            self.lock.lock()
            self.pipesClosed = 2
            self.maybeFire()
            self.lock.unlock()
        }
    }

    func pipeClosed() {
        lock.lock()
        pipesClosed += 1
        maybeFire()
        lock.unlock()
    }

    private func maybeFire() {
        guard !fired, let exit, pipesClosed >= 2 else { return }
        fired = true
        onExit(exit)
    }
}
/// Thread-safe box for accumulating child output across @Sendable callbacks.
final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()

    init(_ value: T) { self.value = value }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

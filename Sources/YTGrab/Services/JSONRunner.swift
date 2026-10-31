import Foundation

enum JSONRunError: Error, Equatable, CustomStringConvertible {
    case outputTooLarge
    case failed(String)
    case signaled(Int32)

    var description: String {
        switch self {
        case .outputTooLarge: return "yt-dlp output exceeded size cap"
        case .failed(let message): return message
        case .signaled(let sig): return "killed by signal \(sig)"
        }
    }
}

/// Optional knobs for a JSON run.
struct JSONRunOptions: Sendable {
    var maxBytes = JSONRunner.defaultMaxBytes
    var onSpawned: (@Sendable (any SpawnedProcess) -> Void)?
}

/// Shared helper for `yt-dlp -J`-style JSON runs (fetch info, browse).
/// Accumulates stdout up to `maxBytes` (memory bound); captures the last
/// stderr line for error reporting. Runs entirely off the main actor.
enum JSONRunner {
    static let defaultMaxBytes = 64 * 1024 * 1024  // 64 MB cap on -J output

    nonisolated static func run(
        spawner: any ProcessSpawner,
        executable: String,
        arguments: [String],
        environment: [String: String],
        options: JSONRunOptions = JSONRunOptions()
    ) async throws -> Data {
        let stdout = LockedBox(Data())
        let tooLarge = LockedBox(false)
        let lastErr = LockedBox("")
        return try await withCheckedThrowingContinuation { cont in
            do {
                let process = try spawner.spawn(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    callbacks: SpawnCallbacks(
                        onStdoutLine: { line in
                            stdout.withLock { buf in
                                if buf.count <= options.maxBytes {
                                    buf.append(Data(line.utf8))
                                    buf.append(0x0A)
                                } else {
                                    tooLarge.withLock { $0 = true }
                                }
                            }
                        },
                        onStderrLine: { line in
                            if !line.isEmpty { lastErr.withLock { $0 = line } }
                        },
                        onExit: { exit in
                            if tooLarge.withLock({ $0 }) {
                                cont.resume(
                                    throwing: JSONRunError.outputTooLarge)
                                return
                            }
                            switch exit {
                            case .exited(0):
                                cont.resume(returning: stdout.withLock { $0 })
                            case .exited(let code):
                                let err = lastErr.withLock { $0 }
                                cont.resume(
                                    throwing: JSONRunError.failed(
                                        err.isEmpty
                                            ? "yt-dlp exited with code \(code)"
                                            : err))
                            case .signaled(let sig):
                                cont.resume(
                                    throwing: JSONRunError.signaled(sig))
                            }
                        }))
                options.onSpawned?(process)
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

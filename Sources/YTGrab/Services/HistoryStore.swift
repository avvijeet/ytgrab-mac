import Foundation

/// Codable snapshot of one job for history.json. Enums are stored as
/// raw strings so unknown future values degrade gracefully on load.
struct HistoryRecord: Codable, Equatable, Sendable {
    var id: UUID
    var videoURL: String
    var title: String
    var outputDirectory: String
    var finalPath: String?
    var state: String
    var progress: Double
    var totalSize: String
    var createdAt: Date
    var finishedAt: Date?
    var errorText: String?
    var quality: String
    var container: String
}

/// Persists the job list to
/// `~/Library/Application Support/YTGrab/history.json`.
///
/// Writes are coalesced on a serial background queue (the "background
/// actor"): every mutation schedules the newest snapshot, but at most
/// one disk write happens per `throttle` window. Each write goes to a
/// temp file and atomically replaces the live one. The list is capped
/// at `maxEntries`, newest-first — trimming drops the oldest tail.
final class HistoryStore: @unchecked Sendable {
    static let maxEntries = 500
    static let filename = "history.json"

    /// Exposed so tests can verify the on-disk file.
    let fileURL: URL
    private let throttle: TimeInterval
    /// Serial queue — the store's only synchronization. All mutable
    /// state below is touched on this queue only (load() excepted).
    private let queue = DispatchQueue(label: "local.ytgrab.history")
    private var pending: [HistoryRecord]?
    private var lastWrite = Date.distantPast
    private var flushScheduled = false

    init(fileURL: URL, throttle: TimeInterval = 0.5) {
        self.fileURL = fileURL
        self.throttle = throttle
    }

    /// Default on-disk location: ~/Library/Application Support/YTGrab/.
    convenience init() {
        let support =
            FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
            ?? URL(
                fileURLWithPath:
                    NSHomeDirectory() + "/Library/Application Support")
        self.init(
            fileURL: support.appendingPathComponent(
                "YTGrab/" + Self.filename))
    }

    /// Synchronous load, run once at launch on the caller's actor; the
    /// file is at most `maxEntries` records so the read is cheap.
    /// A corrupt file is moved aside to `history.json.corrupt` and the
    /// app starts with an empty history.
    func load() -> [HistoryRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([HistoryRecord].self, from: data)
        } catch {
            let backup = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return []
        }
    }

    /// Coalesced write: remembers the newest snapshot and writes at most
    /// once per `throttle` interval. Cheap to call on every mutation.
    func schedule(_ records: [HistoryRecord]) {
        let capped = Array(records.prefix(Self.maxEntries))
        queue.async {
            self.pending = capped
            self.flushIfDue()
        }
    }

    /// Blocks until any pending snapshot has hit disk. Called on app
    /// quit (applicationWillTerminate) and by tests.
    func flush() {
        queue.sync { self.writePending() }
    }

    private func flushIfDue() {
        let remaining = throttle - Date().timeIntervalSince(lastWrite)
        if remaining <= 0 {
            writePending()
        } else if !flushScheduled {
            flushScheduled = true
            queue.asyncAfter(deadline: .now() + remaining) {
                self.flushScheduled = false
                self.writePending()
            }
        }
    }

    private func writePending() {
        guard let records = pending else { return }
        pending = nil
        lastWrite = Date()
        do {
            let data = try JSONEncoder().encode(records)
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            // Atomic replace: write temp, then swap into place.
            let tmp = dir.appendingPathComponent(Self.filename + ".tmp")
            try data.write(to: tmp)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    fileURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: fileURL)
            }
        } catch {
            // Disk full / permission failure: history is best-effort.
            let tmp = fileURL.deletingLastPathComponent()
                .appendingPathComponent(Self.filename + ".tmp")
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}

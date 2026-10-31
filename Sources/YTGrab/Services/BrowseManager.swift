import Foundation
import Observation

@MainActor
@Observable
final class BrowseManager {
    private(set) var results: [BrowseEntry] = []
    private(set) var headerTitle: String?
    var isLoading = false
    var errorText: String?
    var selected: Set<String> = []
    var hasMore = false

    private var lastTarget: BrowseTarget?
    private var endIndex = 0
    private var current: (any SpawnedProcess)?
    private var timeoutTask: Task<Void, Never>?
    private var runID = 0  // invalidates completions from superseded runs
    private let spawner: any ProcessSpawner
    private let pageSize = 30
    private let timeoutSeconds: UInt64 = 60

    private static weak var currentManager: BrowseManager?

    init(spawner: any ProcessSpawner = PosixSpawnSpawner()) {
        self.spawner = spawner
        Self.currentManager = self
    }

    static func terminateCurrent() {
        currentManager?.cancel()
    }

    func run(_ input: String) {
        let target: BrowseTarget
        do {
            target = try URLValidator.classify(input)
        } catch {
            errorText = String(describing: error)
            return
        }
        lastTarget = target
        results = []
        selected = []
        start(target: target, start: 1, end: pageSize)
    }

    func loadMore() {
        guard !isLoading, let target = lastTarget else { return }
        start(target: target, start: endIndex + 1, end: endIndex + pageSize)
    }

    func cancel() {
        runID += 1
        timeoutTask?.cancel()
        timeoutTask = nil
        if let proc = current {
            proc.signalGroup(SIGCONT)
            proc.signalGroup(SIGKILL)
        }
        current = nil
        isLoading = false
    }

    private func start(target: BrowseTarget, start: Int, end: Int) {
        cancel()  // a new browse request kills the previous one
        runID += 1
        let id = runID
        guard let bin = Tooling.ytDLPPath else {
            errorText = "yt-dlp not found"
            return
        }
        isLoading = true
        errorText = nil
        Task { [weak self] in
            do {
                let data = try await JSONRunner.run(
                    spawner: self?.spawner ?? PosixSpawnSpawner(),
                    executable: bin,
                    arguments: YTDLPCommand.browseArguments(
                        target: target, start: start, end: end),
                    environment: Tooling.childEnvironment,
                    options: JSONRunOptions(onSpawned: { proc in
                        Task { @MainActor in
                            guard let self, self.runID == id else { return }
                            self.current = proc
                        }
                    }))
                self?.finish(data: data, end: end, runID: id)
            } catch {
                self?.finish(error: error, runID: id)
            }
        }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.timeout(runID: id)
        }
    }

    private func timeout(runID: Int) {
        guard self.runID == runID else { return }
        cancel()
        errorText = "Browse request timed out after \(timeoutSeconds)s"
    }

    private func finish(data: Data, end: Int, runID: Int) {
        guard self.runID == runID else { return }
        closeRun()
        do {
            let page = try Self.parseListing(data)
            headerTitle = page.title
            // Dedupe by video id: O(1) membership test per entry.
            var seen = Set(results.map(\.id))
            let fresh = page.entries.filter { seen.insert($0.id).inserted }
            results.append(contentsOf: fresh)
            endIndex = end
            hasMore = !page.entries.isEmpty
        } catch {
            errorText = "Could not parse yt-dlp output"
        }
    }

    private func finish(error: Error, runID: Int) {
        guard self.runID == runID else { return }
        closeRun()
        errorText = String(describing: error)
    }

    private func closeRun() {
        timeoutTask?.cancel()
        timeoutTask = nil
        current = nil
        isLoading = false
    }

    static func parseListing(
        _ data: Data
    ) throws -> (
        title: String?, entries: [BrowseEntry]
    ) {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else {
            throw NSError(domain: "ytgrab", code: -1)
        }
        let title = dict["title"] as? String
        if let rawEntries = dict["entries"] as? [[String: Any]] {
            return (title, rawEntries.compactMap(entry(from:)))
        }
        // Single video URL → synthesize a one-element listing.
        if let entry = entry(from: dict) {
            return (title, [entry])
        }
        return (title, [])
    }

    private static func entry(from dict: [String: Any]) -> BrowseEntry? {
        guard let id = dict["id"] as? String,
            URLValidator.isValidVideoID(id)
        else { return nil }
        let viewCount: Int?
        if let intCount = dict["view_count"] as? Int {
            viewCount = intCount
        } else if let doubleCount = dict["view_count"] as? Double {
            viewCount = Int(doubleCount)
        } else {
            viewCount = nil
        }
        return BrowseEntry(
            id: id,
            title: dict["title"] as? String ?? id,
            duration: dict["duration"] as? Double,
            uploader: dict["uploader"] as? String ?? dict["channel"] as? String,
            viewCount: viewCount)
    }
}

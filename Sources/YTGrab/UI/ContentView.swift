import AppKit
import SwiftUI

/// Shared form state so Browse can hand a URL to the Download tab.
@Observable
final class DownloadForm {
    var urlText = ""
    var info: VideoInfo?
    var isFetching = false
    var errorText: String?
}

struct ContentView: View {
    @State private var manager = DownloadManager()
    @State private var browse = BrowseManager()
    @State private var thumbnails = ThumbnailStore()
    @State private var form = DownloadForm()
    @State private var selectedTab: Tab = .downloads

    enum Tab { case downloads, browse, history }

    var body: some View {
        TabView(selection: $selectedTab) {
            DownloadsView(manager: manager, form: form)
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .tag(Tab.downloads)
            BrowseView(
                manager: manager, browse: browse, thumbnails: thumbnails,
                openInDownloadTab: { url in
                    form.urlText = url
                    form.info = nil
                    selectedTab = .downloads
                }
            )
            .tabItem { Label("Browse", systemImage: "magnifyingglass") }
            .tag(Tab.browse)
            HistoryView(manager: manager)
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .tag(Tab.history)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

struct DownloadsView: View {
    @Bindable var manager: DownloadManager
    @Bindable var form: DownloadForm
    @AppStorage("settingsExpanded") private var showSettings = false
    /// Same UserDefaults key DownloadManager.maxConcurrent reads.
    @AppStorage("maxConcurrent") private var maxConcurrentPref = 0
    @State private var searchText = ""

    private var availableQualities: [VideoQuality] {
        guard let info = form.info else { return VideoQuality.browsePresets }
        var list: [VideoQuality] = [.best]
        for quality in VideoQuality.allCases
        where quality.height != nil && info.heights.contains(quality.height ?? -1) {
            list.append(quality)
        }
        return list + [.audioM4A, .audioMP3]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !manager.toolsAvailable {
                missingToolsBanner
            }
            urlRow
            fetchErrorView
            if let info = form.info {
                infoRow(info)
            }
            folderRow
            settingsArea
            globalControls
            searchRow
            jobList
        }
        .padding(16)
    }

    private var missingToolsBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading) {
                Text("Missing: \(manager.missingTools.joined(separator: ", "))")
                    .bold()
                Text("Install with: brew install yt-dlp ffmpeg")
                    .font(.callout)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(10)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    private var urlRow: some View {
        HStack {
            TextField("YouTube URL", text: $form.urlText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { fetch() }
            Button("Fetch info") { fetch() }
                .disabled(
                    form.isFetching || form.urlText.isEmpty
                        || !manager.toolsAvailable)
            if form.isFetching { ProgressView().controlSize(.small) }
        }
    }

    private func infoRow(_ info: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(info.title).font(.headline).lineLimit(2)
            if let uploader = info.uploader {
                Text(uploader).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack {
                Picker("Quality", selection: $manager.selectedQuality) {
                    ForEach(availableQualities) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .frame(maxWidth: 260)
                Spacer()
                Button("Add to queue") { enqueue() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        !manager.toolsAvailable
                            || manager.subtitleLangsError != nil)
            }
        }
        .padding(10)
        .background(
            .quaternary.opacity(0.4),
            in: RoundedRectangle(cornerRadius: 8))
    }

    private var folderRow: some View {
        HStack {
            Text("Save to:")
            Text(manager.saveDirectory)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose…") { chooseDirectory() }
        }
    }

    private var settingsArea: some View {
        CollapsibleSection("Settings", isExpanded: $showSettings) {
            VStack(alignment: .leading, spacing: 8) {
                Picker(
                    "Cookies from browser",
                    selection: $manager.settings.cookieBrowser
                ) {
                    ForEach(CookieBrowser.allCases) { browser in
                        Text(browser.title).tag(browser)
                    }
                }
                .frame(maxWidth: 300)
                Toggle(
                    "Embed metadata",
                    isOn: $manager.settings.embedMetadata)
                Toggle(
                    "Download subtitles",
                    isOn: $manager.settings.downloadSubtitles)
                HStack {
                    TextField(
                        "Languages (e.g. en.*,hi,-live_chat)",
                        text: $manager.settings.subtitleLangs
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .disabled(!manager.settings.downloadSubtitles)
                    if let err = manager.subtitleLangsError {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                }
                Picker(
                    "Container",
                    selection: $manager.settings.container
                ) {
                    ForEach(VideoContainer.allCases) { container in
                        Text(container.title).tag(container)
                    }
                }
                .frame(maxWidth: 220)
                .disabled(manager.selectedQuality.isAudioOnly)
                if manager.selectedQuality.isAudioOnly {
                    Text("Container applies to video downloads only")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Playlist", isOn: $manager.settings.playlist)
            }
            .padding(.top, 4)
        }
    }

    private var globalControls: some View {
        HStack {
            Button("Pause all") { manager.pauseAll() }
                .disabled(!manager.jobs.contains { $0.state == .running })
            Spacer()
            Text(statusCounts)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Live counts plus the concurrency limit readout. "X running" in
    /// the limit counts running+paused — both still hold a slot.
    private var statusCounts: String {
        var queued = 0
        var running = 0
        var paused = 0
        var done = 0
        for job in manager.jobs {
            switch job.state {
            case .queued: queued += 1
            case .running: running += 1
            case .paused: paused += 1
            case .done: done += 1
            default: break
            }
        }
        return "Queued \(queued) · Running \(running) · Paused \(paused)"
            + " · Done \(done) — Concurrent: \(running + paused) running /"
            + " \(manager.maxConcurrent) max"
    }

    private var searchRow: some View {
        HStack {
            TextField(
                "Search title, URL or file path", text: $searchText
            )
            .textFieldStyle(.roundedBorder)
            Stepper(
                "Concurrent: \(manager.maxConcurrent)",
                value: Binding(
                    get: { manager.maxConcurrent },
                    set: { newValue in
                        // Persists via @AppStorage("maxConcurrent") and
                        // pumps queued jobs when the limit is raised.
                        maxConcurrentPref = newValue
                        manager.maxConcurrent = newValue
                    }),
                in: 1...8)
        }
    }

    /// Active jobs (queued/running/paused); everything else is History.
    private var activeJobs: [DownloadJob] {
        let active: Set<JobState> = [.queued, .running, .paused]
        return manager.jobs.filter { active.contains($0.state) }
    }

    /// O(n) substring filter over title, URL and finalPath.
    private var filteredJobs: [DownloadJob] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return activeJobs }
        return activeJobs.filter { $0.matches(query) }
    }

    private var jobList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filteredJobs) { job in
                    JobRowView(job: job, manager: manager)
                    Divider()
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func fetch() {
        let url = form.urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        form.isFetching = true
        form.errorText = nil
        Task {
            do {
                let info = try await manager.fetchInfo(url)
                form.info = info
                form.urlText = url
            } catch {
                form.info = nil
                form.errorText = String(describing: error)
            }
            form.isFetching = false
        }
    }

    private func enqueue() {
        guard let info = form.info else { return }
        manager.enqueue(
            url: form.urlText, title: info.title,
            quality: manager.selectedQuality)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: manager.saveDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            manager.saveDirectory = url.path
        }
    }

    private var fetchErrorView: some View {
        Group {
            if let error = form.errorText {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
    }
}

struct JobRowView: View {
    let job: DownloadJob
    let manager: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.title).lineLimit(1).font(.headline)
                Spacer()
                Text(job.quality.title)
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ProgressView(value: job.percent, total: 100)
                Text(job.statusLine)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(minWidth: 110, alignment: .leading)
            }
            if job.state == .interrupted, let error = job.errorText {
                Text(error)
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(progressDetail).font(.caption).foregroundStyle(.secondary)
                Spacer()
                controls
            }
        }
        .padding(.vertical, 4)
    }

    private var progressDetail: String {
        if job.state == .running && job.phase == .downloading {
            return [
                String(format: "%.1f%%", job.percent),
                job.streamText,
                job.speedText, job.etaText, job.sizeText,
            ].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if job.state == .done, let path = job.finalPath {
            return (path as NSString).lastPathComponent
        }
        return ""
    }

    @ViewBuilder
    private var controls: some View {
        if job.state == .running {
            Button("Pause") { manager.pause(job) }
        }
        if job.state == .paused {
            Button("Resume") { manager.resumePaused(job) }
        }
        if job.state == .running || job.state == .paused || job.state == .queued {
            Button("Stop") { manager.stop(job) }
        }
        if job.isResumable {
            Button("Resume") { manager.resumeDownload(job) }
        }
        if job.state != .running && job.state != .paused {
            Button("Restart") { manager.restart(job) }
        }
        if job.state == .done {
            Button("Re-download") { manager.redownload(job) }
        }
        if let path = job.finalPath {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: path)])
            }
        }
        Button(role: .destructive) {
            manager.remove(job)
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
    }
}

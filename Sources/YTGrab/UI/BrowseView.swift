import AppKit
import SwiftUI

struct BrowseView: View {
    @Bindable var manager: DownloadManager
    @Bindable var browse: BrowseManager
    let thumbnails: ThumbnailStore
    let openInDownloadTab: (String) -> Void

    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(
                    "Search or paste a channel / playlist / video URL",
                    text: $input
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { browse.run(input) }
                Button("Browse") { browse.run(input) }
                    .disabled(
                        browse.isLoading || input.isEmpty
                            || !manager.toolsAvailable)
                if browse.isLoading { ProgressView().controlSize(.small) }
            }

            if let header = browse.headerTitle {
                Text(header).font(.headline)
            }
            if let error = browse.errorText {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            toolbar
            resultsList

            HStack {
                if browse.hasMore {
                    Button("Load more") { browse.loadMore() }
                        .disabled(browse.isLoading)
                }
                Spacer()
                Picker("Quality", selection: $manager.selectedQuality) {
                    ForEach(VideoQuality.browsePresets) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .frame(maxWidth: 240)
            }
        }
        .padding(16)
    }

    private var toolbar: some View {
        HStack {
            Button(allSelected ? "Deselect all" : "Select all") {
                browse.selected =
                    allSelected
                    ? [] : Set(browse.results.map(\.id))
            }
            .disabled(browse.results.isEmpty)
            Button("Download \(browse.selected.count) selected") {
                downloadSelected()
            }
            .disabled(
                browse.selected.isEmpty || !manager.toolsAvailable
                    || manager.subtitleLangsError != nil)
            Spacer()
        }
    }

    private var allSelected: Bool {
        !browse.results.isEmpty
            && browse.selected.count == browse.results.count
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(browse.results) { entry in
                    BrowseRow(
                        entry: entry, browse: browse, manager: manager,
                        thumbnails: thumbnails,
                        openInDownloadTab: openInDownloadTab)
                    Divider()
                }
            }
        }
    }

    private func download(_ entry: BrowseEntry) {
        enqueue([entry])
    }

    private func downloadSelected() {
        let entries = browse.results.filter { browse.selected.contains($0.id) }
        enqueue(entries)
    }

    private func enqueue(_ entries: [BrowseEntry]) {
        for entry in entries {
            guard let url = try? URLValidator.validateVideoURL(entry.watchURL)
            else { continue }
            manager.enqueue(
                url: url, title: entry.title,
                quality: manager.selectedQuality)
        }
    }
}

struct BrowseRow: View {
    let entry: BrowseEntry
    let browse: BrowseManager
    let manager: DownloadManager
    let thumbnails: ThumbnailStore
    let openInDownloadTab: (String) -> Void

    private var isSelected: Bool { browse.selected.contains(entry.id) }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if isSelected { browse.selected.remove(entry.id) } else { browse.selected.insert(entry.id) }
            } label: {
                Image(
                    systemName: isSelected
                        ? "checkmark.square.fill" : "square")
            }
            .buttonStyle(.borderless)
            ThumbnailView(entryID: entry.id, store: thumbnails)
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(2).font(.headline)
                Text(subtitle)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Download") { download() }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Open info in Download tab") {
                openInDownloadTab(entry.watchURL)
            }
            Button("Download") { download() }
        }
    }

    private func download() {
        guard let url = try? URLValidator.validateVideoURL(entry.watchURL)
        else { return }
        manager.enqueue(
            url: url, title: entry.title,
            quality: manager.selectedQuality)
    }

    private var subtitle: String {
        [
            entry.uploader,
            entry.duration.map(Self.formatDuration),
            entry.viewCount.map(Self.formatViews),
        ].compactMap { $0 }.joined(separator: " · ")
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    static func formatViews(_ count: Int) -> String {
        switch count {
        case 1_000_000...:
            return String(format: "%.1fM views", Double(count) / 1e6)
        case 1_000...:
            return String(format: "%.1fK views", Double(count) / 1e3)
        default:
            return "\(count) views"
        }
    }
}

struct ThumbnailView: View {
    let entryID: String
    let store: ThumbnailStore

    var body: some View {
        ZStack {
            if let image = store.image(for: entryID) {
                Image(nsImage: image)
                    .resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                    .overlay(
                        Image(systemName: "film")
                            .foregroundStyle(.secondary))
            }
        }
        // .task cancellation aborts the load when the row scrolls away.
        .task { await store.load(entryID) }
    }
}

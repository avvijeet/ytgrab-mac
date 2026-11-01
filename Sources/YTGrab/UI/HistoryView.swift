import SwiftUI

/// Non-active jobs — everything not queued/running/paused (done,
/// failed, stopped, cancelled, interrupted) — with clear actions.
struct HistoryView: View {
    @Bindable var manager: DownloadManager
    @State private var searchText = ""
    @State private var confirmClearHistory = false

    /// Same active set DownloadManager.clearHistory() keeps.
    private var historyJobs: [DownloadJob] {
        let active: Set<JobState> = [.queued, .running, .paused]
        return manager.jobs.filter { !active.contains($0.state) }
    }

    /// O(n) substring filter over title, URL and finalPath.
    private var filteredJobs: [DownloadJob] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return historyJobs }
        return historyJobs.filter { $0.matches(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            searchRow
            jobList
        }
        .padding(16)
    }

    private var headerRow: some View {
        HStack {
            Button("Clear finished") { manager.clearFinished() }
            Button("Clear history") { confirmClearHistory = true }
                .disabled(historyJobs.isEmpty)
            Spacer()
            Text("\(historyJobs.count) entries")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "Clear all non-active history entries?",
            isPresented: $confirmClearHistory, titleVisibility: .visible
        ) {
            Button("Clear history", role: .destructive) {
                manager.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var searchRow: some View {
        TextField(
            "Search title, URL or file path", text: $searchText
        )
        .textFieldStyle(.roundedBorder)
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
        .overlay {
            if historyJobs.isEmpty {
                Text("No history yet").foregroundStyle(.secondary)
            }
        }
    }
}

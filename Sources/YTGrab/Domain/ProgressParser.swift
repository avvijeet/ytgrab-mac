import Foundation

struct ProgressUpdate: Equatable, Sendable {
    var percent: Double?
    var speed: String?
    var eta: String?
    var total: String?
}

enum ProgressParser {
    /// Parses a line emitted by
    /// `--progress-template "download:%(progress._percent_str)s|
    ///  %(progress._speed_str)s|%(progress._eta_str)s|
    ///  %(progress._total_bytes_str)s"`.
    /// Fields arrive right-aligned/padded; unknowns render as
    /// "N/A", "NA" or " Unknown B/s".
    static func parse(_ line: String) -> ProgressUpdate? {
        let parts = line.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let fields = parts.map { $0.trimmingCharacters(in: .whitespaces) }
        return ProgressUpdate(
            percent: parsePercent(fields[0]),
            speed: norm(fields[1]),
            eta: norm(fields[2]),
            total: norm(fields[3]))
    }

    private static func parsePercent(_ text: String) -> Double? {
        var trimmed = text
        guard trimmed.hasSuffix("%") else { return nil }
        trimmed.removeLast()
        guard let value = Double(trimmed) else { return nil }
        return value
    }

    private static func norm(_ text: String) -> String? {
        (text.isEmpty || text == "N/A" || text == "NA" || text == "Unknown B/s") ? nil : text
    }

    /// Post-processor stage lines (merge, remux, metadata, subtitles,
    /// extract-audio, fixups). Used to show the "Processing…" phase.
    static func isPostprocessLine(_ line: String) -> Bool {
        postprocessPrefixes.contains { line.hasPrefix($0) }
    }

    static let postprocessPrefixes: [String] = [
        "[Merger]", "[VideoRemuxer]", "[VideoConvertor]", "[ExtractAudio]",
        "[Metadata]", "[EmbedSubtitle]", "[SubtitlesConvertor]",
        "[EmbedThumbnail]", "[ThumbnailsConvertor]", "[ModifyChapters]",
        "[SplitChapters]", "[FixupM3u8]", "[FixupMtime]", "[FixupTimestamp]",
        "[FixupDuplicateThumbnails]", "[MoveFiles]", "[SponsorBlock]",
        "[MediaMetadata]", "[TCE]", "[VideoConcatenator]",
    ]

    /// `--print after_move:filepath` emits the final path as a bare
    /// absolute-path line on stdout.
    static func isFilepathLine(_ line: String) -> Bool {
        line.hasPrefix("/")
    }
}

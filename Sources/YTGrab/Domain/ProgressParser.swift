import Foundation

struct ProgressUpdate: Equatable, Sendable {
    var percent: Double?
    var speed: String?
    var eta: String?
    var total: String?
}

/// How one yt-dlp stdout line affects the job row. `classify` is the
/// single pass over each line — prefix/split checks only, no regex.
enum ParsedLineKind: Equatable, Sendable {
    /// `a|b|c|d` template progress line.
    case progress(ProgressUpdate)
    /// "[youtube] …" — extractor work before any download starts.
    /// Payload is the meaningful tail ("Downloading webpage").
    case preparing(detail: String?)
    /// "[info] …" — format resolution; payload is the expected stream
    /// count parsed from "Downloading N format(s): sel1+sel2".
    case fetchingFormats(expectedStreams: Int?)
    /// "[download] Destination: <path>" — one per output stream.
    case destination(path: String)
    /// "[download]  N% of …" — native per-stream completion summary.
    case streamPercent(Double)
    /// "[download] … has already been downloaded" — stream is complete.
    case alreadyDownloaded
    /// "[Merger] …" — ffmpeg merge phase.
    case merging
    /// Any other postprocessor line ([ExtractAudio], [Metadata], …).
    case postprocess
    /// Bare absolute path from `--print after_move:filepath`.
    case filepath(String)
    case ignored
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

    /// One-pass classification of a stdout line. Order matters: the
    /// template check runs first, then bracketed prefixes, and the bare
    /// filepath heuristic always comes last. O(len(line)) throughout.
    static func classify(_ line: String) -> ParsedLineKind {
        if let update = parse(line) { return .progress(update) }
        if line.hasPrefix("[download]") {
            if let path = destinationPath(line) {
                return .destination(path: path)
            }
            if let percent = summaryPercent(line) {
                return .streamPercent(percent)
            }
            if line.contains("has already been downloaded") {
                return .alreadyDownloaded
            }
            return .ignored
        }
        if line.hasPrefix("[youtube]") {
            return .preparing(detail: preparingDetail(line))
        }
        if line.hasPrefix("[info]") {
            return .fetchingFormats(expectedStreams: expectedStreamCount(line))
        }
        if isPostprocessLine(line) {
            return line.hasPrefix("[Merger]") ? .merging : .postprocess
        }
        if isFilepathLine(line) { return .filepath(line) }
        return .ignored
    }

    // MARK: - Non-template line readers

    /// "[download] Destination: /path/to/file.f397.mp4" → the path.
    static func destinationPath(_ line: String) -> String? {
        let prefix = "[download] Destination: "
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    /// "[download]  45.0% of   357.15MiB in 00:02:03 at 2.89MiB/s" → 45.0.
    /// Emitted once at the end of each stream's download.
    static func summaryPercent(_ line: String) -> Double? {
        guard line.hasPrefix("[download]") else { return nil }
        var rest = line.dropFirst("[download]".count)
        while rest.first == " " { rest = rest.dropFirst() }
        guard let percentMark = rest.firstIndex(of: "%") else { return nil }
        guard let value = Double(rest[..<percentMark]) else { return nil }
        return rest[rest.index(after: percentMark)...].hasPrefix(" of")
            ? value : nil
    }

    /// "[youtube] <id>: <action>" → <action>. Nested extractor tags
    /// ("[jsc:deno]") are stripped; when the tail is a bare URL the
    /// leading description ("Extracting URL") is more readable.
    static func preparingDetail(_ line: String) -> String? {
        guard line.hasPrefix("[youtube]") else { return nil }
        var rest = line.dropFirst("[youtube]".count)
        while rest.first == " " { rest = rest.dropFirst() }
        while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            rest = rest[rest.index(after: close)...]
            while rest.first == " " { rest = rest.dropFirst() }
        }
        if let lastColon = rest.range(of: ": ", options: .backwards) {
            let tail = rest[lastColon.upperBound...]
            if tail.contains("://"),
                let firstColon = rest.range(of: ": ")
            {
                rest = rest[..<firstColon.lowerBound]
            } else {
                rest = tail
            }
        }
        let detail = rest.trimmingCharacters(in: .whitespaces)
        return detail.isEmpty ? nil : detail
    }

    /// "[info] <id>: Downloading N format(s): 398+251" → expected stream
    /// count. N counts format selections, so when a selection names
    /// '+'-joined streams we take the larger of the two; destination
    /// counting still wins at runtime (K = max(expected, seen)).
    static func expectedStreamCount(_ line: String) -> Int? {
        guard line.hasPrefix("[info]"),
            let marker = line.range(of: " format(s)"),
            let downloading = line.range(
                of: "Downloading ", options: .backwards,
                range: line.startIndex..<marker.lowerBound),
            let count = Int(line[downloading.upperBound..<marker.lowerBound])
        else { return nil }
        let tail = line[marker.upperBound...]
        guard tail.hasPrefix(": "),
            let first = tail.dropFirst(2).split(separator: ",").first
        else { return count }
        return max(count, first.split(separator: "+").count)
    }

    // MARK: - Existing helpers

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

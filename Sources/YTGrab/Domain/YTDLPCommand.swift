import Foundation

/// Pure argv construction. Every flag is verified against
/// `yt-dlp --help` of the installed version (see docs/SOURCES.md).
enum YTDLPCommand {
    /// Flags applied to every invocation, verified against
    /// `yt-dlp --help` (see docs/SOURCES.md).
    static let hardeningFlags = ["--ignore-config", "--no-exec", "--no-plugin-dirs"]

    static let progressTemplate =
        "download:%(progress._percent_str)s|%(progress._speed_str)s"
        + "|%(progress._eta_str)s|%(progress._total_bytes_str)s"
    static let outputTemplate = "%(title).150B [%(id)s].%(ext)s"

    static func infoArguments(url: String) -> [String] {
        [
            "-J", "--no-playlist", "--no-warnings",
        ] + hardeningFlags + [
            "--", url,
        ]
    }

    static func downloadArguments(spec: DownloadSpec) -> [String] {
        var args =
            hardeningFlags + [
                "--newline",
                "--progress-template", progressTemplate,
                "--retries", "10",
                "--fragment-retries", "10",
                "--concurrent-fragments", "4",
                "--windows-filenames",
                "-P", spec.outputDirectory,
                "-o", outputTemplate,
                "--ffmpeg-location", spec.ffmpegDirectory,
                "--print", "after_move:filepath",
            ]
        switch spec.quality {
        case .best:
            args += ["-f", "bv*+ba/b"]
            args += spec.settings.container.formatSort
            args += [
                "--merge-output-format",
                spec.settings.container.rawValue,
            ]
        case .h2160, .h1440, .h1080, .h720, .h480, .h360:
            let cap = spec.quality.height ?? 0
            args += ["-f", "bv*[height<=\(cap)]+ba/b[height<=\(cap)]"]
            args += spec.settings.container.formatSort
            args += [
                "--merge-output-format",
                spec.settings.container.rawValue,
            ]
        case .audioM4A:
            args += ["-f", "ba/b", "-x", "--audio-format", "m4a"]
        case .audioMP3:
            args += ["-f", "ba/b", "-x", "--audio-format", "mp3"]
        }
        if spec.freshStart {
            args += ["--no-continue", "--force-overwrites"]
        } else {
            args += ["--continue"]
        }
        if !spec.settings.playlist {
            args += ["--no-playlist"]
        }
        if let browser = spec.settings.cookieBrowser.flagValue {
            args += ["--cookies-from-browser", browser]
        }
        if spec.settings.embedMetadata {
            args += ["--embed-metadata"]
        }
        if spec.settings.downloadSubtitles {
            // Single argv element; value validated by SubtitleLangsValidator.
            args += [
                "--write-subs", "--embed-subs",
                "--sub-langs", spec.settings.subtitleLangs,
            ]
        }
        args += ["--", spec.url]
        return args
    }

    /// Flat-playlist metadata listing for Browse.
    /// `start`/`end` form the `--playlist-items` window (1-based).
    /// For searches the extractor prefix itself is widened
    /// (`ytsearchN:`), so `end` also controls result count.
    static func browseArguments(target: BrowseTarget, start: Int, end: Int) -> [String] {
        var args =
            hardeningFlags + [
                "--flat-playlist", "-J", "--no-warnings",
                "--playlist-items", "\(start):\(end)",
            ]
        switch target {
        case .search(let query):
            args += ["--", "ytsearch\(end):\(query)"]
        case .url(let url):
            args += ["--", url]
        }
        return args
    }
}

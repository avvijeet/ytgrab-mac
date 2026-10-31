import Foundation

// MARK: - Download configuration

enum VideoQuality: String, CaseIterable, Identifiable, Sendable {
    case best, h2160, h1440, h1080, h720, h480, h360, audioM4A, audioMP3

    var id: String { rawValue }

    var title: String {
        switch self {
        case .best: return "Best available"
        case .h2160: return "2160p"
        case .h1440: return "1440p"
        case .h1080: return "1080p"
        case .h720: return "720p"
        case .h480: return "480p"
        case .h360: return "360p"
        case .audioM4A: return "Audio only (m4a)"
        case .audioMP3: return "Audio only (mp3)"
        }
    }

    var height: Int? {
        switch self {
        case .h2160: return 2160
        case .h1440: return 1440
        case .h1080: return 1080
        case .h720: return 720
        case .h480: return 480
        case .h360: return 360
        case .best, .audioM4A, .audioMP3: return nil
        }
    }

    var isAudioOnly: Bool { self == .audioM4A || self == .audioMP3 }

    /// Presets offered in Browse (no per-video format probing there).
    static let browsePresets: [VideoQuality] = [
        .best, .h1080, .h720, .h480, .h360, .audioM4A, .audioMP3,
    ]
}

enum VideoContainer: String, CaseIterable, Identifiable, Sendable {
    case mp4, mkv, webm

    var id: String { rawValue }

    var title: String { rawValue }

    /// Format-sort (`-S`) applied so the chosen streams are native to the
    /// container, avoiding runtime remux failures. Empty = yt-dlp default.
    /// `ext` accepts two preferred values: video first, audio second.
    var formatSort: [String] {
        switch self {
        case .mp4, .mkv: return []
        case .webm: return ["-S", "ext:webm:webm"]
        }
    }
}

enum CookieBrowser: String, CaseIterable, Identifiable, Sendable {
    case none, chrome, safari, firefox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .chrome: return "Chrome"
        case .safari: return "Safari"
        case .firefox: return "Firefox"
        }
    }

    var flagValue: String? { self == .none ? nil : rawValue }
}

struct DownloadSettings: Equatable, Sendable {
    var cookieBrowser: CookieBrowser = .none
    var embedMetadata = false
    var downloadSubtitles = false
    var subtitleLangs = "en.*"
    var container: VideoContainer = .mp4
    var playlist = false
}

struct DownloadSpec: Equatable, Sendable {
    var url: String
    var quality: VideoQuality
    var outputDirectory: String
    var ffmpegDirectory: String
    var settings: DownloadSettings
    /// true = restart from zero (--no-continue --force-overwrites)
    /// false = resume partial .part files (--continue)
    var freshStart: Bool
}

// MARK: - Results

struct VideoInfo: Equatable, Sendable {
    var title: String
    var id: String
    var heights: [Int]
    var duration: TimeInterval?
    var uploader: String?
}

enum BrowseTarget: Equatable, Sendable {
    case search(String)
    case url(String)
}

struct BrowseEntry: Identifiable, Equatable, Sendable {
    let id: String  // YouTube video id
    var title: String
    var duration: TimeInterval?
    var uploader: String?
    var viewCount: Int?

    var watchURL: String { "https://www.youtube.com/watch?v=\(id)" }
}

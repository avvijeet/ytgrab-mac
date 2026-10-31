import Foundation

enum ValidationError: Error, Equatable, CustomStringConvertible {
    case empty
    case tooLong
    case illegalCharacters
    case notHTTPS
    case badHost
    case userInfoNotAllowed
    case unsupportedPath
    case missingParameter(String)
    case invalidQueryKey(String)

    var description: String {
        switch self {
        case .empty: return "Input is empty"
        case .tooLong: return "Input exceeds 2048 characters"
        case .illegalCharacters: return "Input contains illegal characters"
        case .notHTTPS: return "Only https:// URLs are allowed"
        case .badHost: return "Host is not a supported YouTube domain"
        case .userInfoNotAllowed: return "Userinfo in URLs is not allowed"
        case .unsupportedPath: return "Unsupported URL path"
        case .missingParameter(let name): return "Missing required parameter: \(name)"
        case .invalidQueryKey(let key): return "Unsupported query parameter: \(key)"
        }
    }
}

enum URLValidator {
    static let allowedHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com",
        "music.youtube.com", "youtu.be",
    ]
    static let allowedQueryKeys: Set<String> = [
        "v", "list", "t", "si", "pp", "index", "feature",
    ]
    static let videoIDPattern = "^[A-Za-z0-9_-]{11}$"
    static let channelTabs: Set<String> = [
        "videos", "shorts", "streams", "playlists", "featured",
    ]

    static func isValidVideoID(_ text: String) -> Bool {
        text.range(of: videoIDPattern, options: .regularExpression) != nil
    }

    // MARK: - Video URL (Download tab)

    /// Validates a YouTube video URL for the Download tab.
    /// Enforces: https only, whitelisted host, no userinfo, length limit,
    /// no whitespace/control chars. Returns the validated string unchanged.
    @discardableResult
    static func validateVideoURL(_ raw: String) throws -> String {
        _ = try checkedComponents(raw)
        return raw
    }

    // MARK: - Search query

    static func sanitizeSearchQuery(_ raw: String) throws -> String {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ValidationError.empty }
        guard query.count <= 200 else { throw ValidationError.tooLong }
        for scalar in query.unicodeScalars
        where CharacterSet.controlCharacters.contains(scalar)
            || scalar.value == 0x7F
        {
            throw ValidationError.illegalCharacters
        }
        return query
    }

    // MARK: - Browse input classification

    /// Decides whether the input is a URL to validate or a plain search query.
    /// A bare `@handle` is treated as `https://www.youtube.com/@handle/videos`.
    static func classify(_ raw: String) throws -> BrowseTarget {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }

        if trimmed.hasPrefix("@") {
            return .url(
                try validateBrowseURL(
                    "https://www.youtube.com/" + trimmed))
        }
        let lower = trimmed.lowercased()
        let hasHostPrefix = allowedHosts.contains { lower.hasPrefix($0) }
        if trimmed.contains("://") || hasHostPrefix {
            var candidate = trimmed
            if !candidate.contains("://") {
                candidate = "https://" + candidate
            }
            return .url(try validateBrowseURL(candidate))
        }
        return .search(try sanitizeSearchQuery(trimmed))
    }

    // MARK: - Channel / playlist / video URL (Browse tab)

    /// Validates channel, playlist and video URL shapes. Bare channel URLs
    /// are normalized to their `/videos` tab. Returns the validated URL
    /// string (canonicalized to https:// + host + path + allowed query keys).
    @discardableResult
    static func validateBrowseURL(_ raw: String) throws -> String {
        let comps = try checkedComponents(raw)
        if let items = comps.queryItems {
            for item in items where !allowedQueryKeys.contains(item.name) {
                throw ValidationError.invalidQueryKey(item.name)
            }
        }
        guard let host = comps.host?.lowercased() else {
            throw ValidationError.badHost
        }
        var path = comps.path
        if path.hasSuffix("/") && path.count > 1 {
            path = String(path.dropLast())
        }
        let segments = path.split(separator: "/").map(String.init)
        return try matchPath(
            host: host, path: path, segments: segments, comps: comps)
    }

    private static func matchPath(
        host: String, path: String, segments: [String],
        comps: URLComponents
    ) throws -> String {
        if host == "youtu.be" {
            guard segments.count == 1, isValidVideoID(segments[0]) else {
                throw ValidationError.unsupportedPath
            }
            return canonical("/watch", videoID: segments[0])
        }
        guard let first = segments.first else {
            throw ValidationError.unsupportedPath
        }
        if first.hasPrefix("@") {
            return try matchChannelPath(
                path: path, segments: segments, kind: .handle)
        }
        switch first {
        case "channel":
            return try matchChannelPath(
                path: path, segments: segments, kind: .channelID)
        case "c", "user":
            return try matchChannelPath(
                path: path, segments: segments, kind: .legacyName)
        case "playlist":
            return try matchPlaylist(segments: segments, comps: comps)
        case "watch":
            return try matchWatch(segments: segments, comps: comps)
        case "shorts", "embed", "live":
            guard segments.count == 2, isValidVideoID(segments[1]) else {
                throw ValidationError.unsupportedPath
            }
            return canonical("/watch", videoID: segments[1])
        default:
            throw ValidationError.unsupportedPath
        }
    }

    private enum ChannelKind { case handle, channelID, legacyName }

    private static func isName(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 100
            && text.range(
                of: "^[A-Za-z0-9._-]+$",
                options: .regularExpression) != nil
    }

    private static func canonical(_ path: String, videoID: String) -> String {
        canonical(path, query: URLQueryItem(name: "v", value: videoID))
    }

    private static func canonical(
        _ path: String,
        query: URLQueryItem? = nil
    ) -> String {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "www.youtube.com"  // normalize all youtube hosts
        comps.path = path
        if let query { comps.queryItems = [query] }
        return comps.string ?? "https://www.youtube.com\(path)"
    }

    /// `/@handle`, `/channel/UC..`, `/c/name`, `/user/name` with an
    /// optional trailing tab; bare names get `/videos` appended.
    private static func matchChannelPath(
        path: String, segments: [String], kind: ChannelKind
    ) throws -> String {
        let nameIndex = kind == .handle ? 0 : 1
        guard segments.count > nameIndex else {
            throw ValidationError.unsupportedPath
        }
        let name =
            kind == .handle
            ? String(segments[nameIndex].dropFirst()) : segments[nameIndex]
        guard isName(name) else { throw ValidationError.unsupportedPath }
        if kind == .channelID && !name.hasPrefix("UC") {
            throw ValidationError.unsupportedPath
        }
        let tabIndex = nameIndex + 1
        if segments.count == tabIndex {
            return canonical(path + "/videos")
        }
        guard segments.count == tabIndex + 1,
            channelTabs.contains(segments[tabIndex])
        else { throw ValidationError.unsupportedPath }
        return canonical(path)
    }

    private static func matchPlaylist(
        segments: [String], comps: URLComponents
    ) throws -> String {
        guard segments.count == 1 else {
            throw ValidationError.unsupportedPath
        }
        guard
            let list = comps.queryItems?
                .first(where: { $0.name == "list" })?.value,
            list.range(
                of: "^[A-Za-z0-9_-]{1,128}$",
                options: .regularExpression) != nil
        else { throw ValidationError.missingParameter("list") }
        return canonical(
            "/playlist",
            query: URLQueryItem(name: "list", value: list))
    }

    private static func matchWatch(
        segments: [String], comps: URLComponents
    ) throws -> String {
        guard segments.count == 1 else {
            throw ValidationError.unsupportedPath
        }
        guard
            let videoID = comps.queryItems?
                .first(where: { $0.name == "v" })?.value,
            isValidVideoID(videoID)
        else { throw ValidationError.missingParameter("v") }
        return canonical("/watch", videoID: videoID)
    }

    // MARK: - Shared checks

    private static func checkedComponents(_ raw: String) throws -> URLComponents {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }
        guard trimmed.count <= 2048 else { throw ValidationError.tooLong }
        guard !trimmed.hasPrefix("-") else {
            throw ValidationError.illegalCharacters
        }
        for scalar in trimmed.unicodeScalars
        where CharacterSet.controlCharacters.contains(scalar)
            || CharacterSet.whitespacesAndNewlines.contains(scalar)
            || scalar.value == 0x7F
        {
            throw ValidationError.illegalCharacters
        }
        guard let comps = URLComponents(string: trimmed) else {
            throw ValidationError.illegalCharacters
        }
        guard comps.scheme?.lowercased() == "https" else {
            throw ValidationError.notHTTPS
        }
        guard comps.user == nil, comps.password == nil else {
            throw ValidationError.userInfoNotAllowed
        }
        guard let host = comps.host?.lowercased(),
            allowedHosts.contains(host)
        else { throw ValidationError.badHost }
        let path = comps.path
        if path.contains("\\") || path.contains("//")
            || path.split(separator: "/").contains("..")
        {
            throw ValidationError.unsupportedPath
        }
        return comps
    }
}

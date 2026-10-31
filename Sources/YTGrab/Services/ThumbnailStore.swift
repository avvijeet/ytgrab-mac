import AppKit
import Foundation
import Observation

/// Loads video thumbnails exclusively from https://i.ytimg.com, where the
/// URL is constructed from a regex-validated video id. Thumbnail URLs from
/// yt-dlp JSON are never used. Ephemeral session: no cookies, no disk
/// cache; images kept in a bounded NSCache (count and cost limits).
@MainActor
@Observable
final class ThumbnailStore {
    /// Version counter: bumped on each cache store so @Observable views
    /// re-render (NSCache itself is not observable).
    private(set) var version = 0

    private let cache: NSCache<NSString, NSImage> = {
        let newCache = NSCache<NSString, NSImage>()
        newCache.countLimit = 400
        newCache.totalCostLimit = 64 * 1024 * 1024  // 64 MB
        return newCache
    }()
    private var inflight: Set<String> = []

    @ObservationIgnored
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    func image(for videoID: String) -> NSImage? {
        _ = version  // establish observation dependency
        return cache.object(forKey: videoID as NSString)
    }

    /// Awaited from a view's `.task`; cancelling the task (row scrolled
    /// offscreen) aborts the underlying URLSession request.
    func load(_ videoID: String) async {
        guard cache.object(forKey: videoID as NSString) == nil,
            !inflight.contains(videoID),
            URLValidator.isValidVideoID(videoID)
        else { return }
        inflight.insert(videoID)
        defer { inflight.remove(videoID) }
        // Host is a fixed literal; only the regex-validated id is inserted.
        guard
            let url = URL(
                string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg"),
            url.host == "i.ytimg.com"
        else { return }
        do {
            let (data, response) = try await session.data(from: url)
            guard !Task.isCancelled,
                let http = response as? HTTPURLResponse,
                http.statusCode == 200,
                let image = NSImage(data: data)
            else { return }
            cache.setObject(
                image, forKey: videoID as NSString,
                cost: data.count)
            version += 1
        } catch {
            // Thumbnails are best-effort; a missing one is not an error.
        }
    }
}

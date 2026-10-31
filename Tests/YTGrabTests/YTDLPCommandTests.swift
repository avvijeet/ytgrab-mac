import Testing

@testable import YTGrab

@Suite("YTDLPCommand — download args")
struct DownloadArgsTests {
    let base = DownloadSpec(
        url: "https://www.youtube.com/watch?v=R00Tgpx36l8",
        quality: .best,
        outputDirectory: "/tmp/out",
        ffmpegDirectory: "/opt/homebrew/bin",
        settings: DownloadSettings(),
        freshStart: false)

    @Test("double dash immediately precedes the URL")
    func dashDashBeforeURL() {
        let args = YTDLPCommand.downloadArguments(spec: base)
        let idx = args.firstIndex(of: "--")
        #expect(idx != nil)
        #expect(idx == args.count - 2)
        #expect(args.last == base.url)
    }

    @Test(
        "format selector per quality",
        arguments: [
            (VideoQuality.best, "bv*+ba/b"),
            (.h2160, "bv*[height<=2160]+ba/b[height<=2160]"),
            (.h1080, "bv*[height<=1080]+ba/b[height<=1080]"),
            (.h720, "bv*[height<=720]+ba/b[height<=720]"),
            (.h480, "bv*[height<=480]+ba/b[height<=480]"),
            (.h360, "bv*[height<=360]+ba/b[height<=360]"),
            (.audioM4A, "ba/b"),
            (.audioMP3, "ba/b"),
        ])
    func formatSelector(quality: VideoQuality, expected: String) {
        var spec = base
        spec.quality = quality
        let args = YTDLPCommand.downloadArguments(spec: spec)
        let idx = args.firstIndex(of: "-f")
        #expect(idx != nil)
        #expect(idx.flatMap { args[safe: $0 + 1] } == expected)
    }

    @Test("video qualities merge to mp4; audio does not")
    func mergeFormat() {
        var spec = base
        spec.quality = .h720
        #expect(
            YTDLPCommand.downloadArguments(spec: spec)
                .contains("--merge-output-format"))
        spec.quality = .audioM4A
        let args = YTDLPCommand.downloadArguments(spec: spec)
        #expect(!args.contains("--merge-output-format"))
        #expect(args.contains("-x"))
        #expect(args.firstIndex(of: "--audio-format").map { args[$0 + 1] } == "m4a")
    }

    @Test("resume uses --continue; restart uses --no-continue --force-overwrites")
    func resumeVsRestart() {
        var spec = base
        #expect(YTDLPCommand.downloadArguments(spec: spec).contains("--continue"))
        spec.freshStart = true
        let args = YTDLPCommand.downloadArguments(spec: spec)
        #expect(args.contains("--no-continue"))
        #expect(args.contains("--force-overwrites"))
        #expect(!args.contains("--continue"))
    }

    @Test("hardening and required flags present")
    func hardening() {
        let args = YTDLPCommand.downloadArguments(spec: base)
        for flag in [
            "--ignore-config", "--no-exec", "--no-plugin-dirs",
            "--newline", "--no-playlist", "--windows-filenames",
        ] {
            #expect(args.contains(flag), "\(flag) missing")
        }
        #expect(args.firstIndex(of: "-P").map { args[$0 + 1] } == "/tmp/out")
        #expect(
            args.firstIndex(of: "--ffmpeg-location").map { args[$0 + 1] }
                == "/opt/homebrew/bin")
        #expect(args.firstIndex(of: "--print").map { args[$0 + 1] } == "after_move:filepath")
        #expect(args.contains(YTDLPCommand.progressTemplate))
    }

    @Test("settings toggles")
    func settings() {
        var spec = base
        spec.settings = DownloadSettings(
            cookieBrowser: .chrome, embedMetadata: true,
            downloadSubtitles: true, playlist: true)
        let args = YTDLPCommand.downloadArguments(spec: spec)
        #expect(args.contains("--cookies-from-browser"))
        #expect(args.firstIndex(of: "--cookies-from-browser").map { args[$0 + 1] } == "chrome")
        #expect(args.contains("--embed-metadata"))
        #expect(args.contains("--write-subs"))
        #expect(args.contains("--embed-subs"))
        #expect(args.contains("--sub-langs"))
        #expect(!args.contains("--no-playlist"))  // playlist on
    }
}

@Suite("YTDLPCommand — browse args")
struct BrowseArgsTests {
    @Test("search query is single argv after --, prefixed ytsearchN:")
    func search() {
        let args = YTDLPCommand.browseArguments(
            target: .search("--exec rm -rf"), start: 1, end: 30)
        #expect(args.last == "ytsearch30:--exec rm -rf")
        #expect(args[args.count - 2] == "--")
        #expect(args.contains("--flat-playlist"))
        #expect(args.contains("--playlist-items"))
    }

    @Test("channel URL after -- with item window")
    func channel() {
        let url = "https://www.youtube.com/@LatentX/videos"
        let args = YTDLPCommand.browseArguments(
            target: .url(url), start: 31, end: 60)
        #expect(args.last == url)
        #expect(args[args.count - 2] == "--")
        let idx = args.firstIndex(of: "--playlist-items")
        #expect(idx.flatMap { args[safe: $0 + 1] } == "31:60")
    }
}

@Suite("YTDLPCommand — info args")
struct InfoArgsTests {
    @Test("info argv ends with -- url")
    func info() {
        let url = "https://www.youtube.com/watch?v=R00Tgpx36l8"
        let args = YTDLPCommand.infoArguments(url: url)
        #expect(args.last == url)
        #expect(args[args.count - 2] == "--")
        #expect(args.contains("-J"))
        #expect(args.contains("--no-playlist"))
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

@Suite("YTDLPCommand — container and subtitle langs")
struct ContainerTests {
    let base = DownloadSpec(
        url: "https://www.youtube.com/watch?v=R00Tgpx36l8",
        quality: .h720,
        outputDirectory: "/tmp/out",
        ffmpegDirectory: "/opt/homebrew/bin",
        settings: DownloadSettings(),
        freshStart: false)

    @Test(
        "container flag per enum",
        arguments: [
            (VideoContainer.mp4, "mp4"), (.mkv, "mkv"), (.webm, "webm"),
        ])
    func container(container: VideoContainer, flag: String) {
        var spec = base
        spec.settings.container = container
        let args = YTDLPCommand.downloadArguments(spec: spec)
        let idx = args.firstIndex(of: "--merge-output-format")
        #expect(idx.flatMap { args[safe: $0 + 1] } == flag)
    }

    @Test("webm adds ext sort; mp4 and mkv do not")
    func webmSort() {
        var spec = base
        spec.settings.container = .webm
        let args = YTDLPCommand.downloadArguments(spec: spec)
        let idx = args.firstIndex(of: "-S")
        #expect(idx.flatMap { args[safe: $0 + 1] } == "ext:webm:webm")
        spec.settings.container = .mp4
        #expect(!YTDLPCommand.downloadArguments(spec: spec).contains("-S"))
        spec.settings.container = .mkv
        #expect(!YTDLPCommand.downloadArguments(spec: spec).contains("-S"))
    }

    @Test("audio presets ignore the container")
    func audioIgnoresContainer() {
        var spec = base
        spec.quality = .audioM4A
        spec.settings.container = .webm
        let args = YTDLPCommand.downloadArguments(spec: spec)
        #expect(!args.contains("--merge-output-format"))
        #expect(!args.contains("-S"))
    }

    @Test("subtitle langs passed as one argv element")
    func subLangs() {
        var spec = base
        spec.settings.downloadSubtitles = true
        spec.settings.subtitleLangs = "en.*,hi,-live_chat"
        let args = YTDLPCommand.downloadArguments(spec: spec)
        let idx = args.firstIndex(of: "--sub-langs")
        #expect(idx.flatMap { args[safe: $0 + 1] } == "en.*,hi,-live_chat")
        #expect(args.contains("--write-subs"))
        #expect(args.contains("--embed-subs"))
    }
}

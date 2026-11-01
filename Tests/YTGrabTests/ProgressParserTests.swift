import Testing

@testable import YTGrab

@Suite("ProgressParser")
struct ProgressParserTests {
    @Test(
        "parses real captured progress lines",
        arguments: [
            (
                "  3.3%| 399.45KiB/s|03:11|  77.18MiB",
                ProgressUpdate(
                    percent: 3.3, speed: "399.45KiB/s",
                    eta: "03:11", total: "77.18MiB")
            ),
            (
                "  0.0%|  18.20KiB/s|01:12:22|  77.18MiB",
                ProgressUpdate(
                    percent: 0.0, speed: "18.20KiB/s",
                    eta: "01:12:22", total: "77.18MiB")
            ),
            (
                "100.0%|  12.00MiB/s|NA| 118.39MiB",
                ProgressUpdate(
                    percent: 100.0, speed: "12.00MiB/s",
                    eta: nil, total: "118.39MiB")
            ),
            (
                "  N/A%| Unknown B/s|N/A|      N/A",
                ProgressUpdate(percent: nil, speed: nil, eta: nil, total: nil)
            ),
        ])
    func parseLines(line: String, expected: ProgressUpdate) {
        #expect(ProgressParser.parse(line) == expected)
    }

    @Test(
        "rejects non-progress lines",
        arguments: [
            "[youtube] Extracting URL: https://www.youtube.com/watch?v=x",
            "[download] Destination: /tmp/file.mp4",
            "/tmp/file.mp4",
            "[Merger] Merging formats into \"/tmp/file.mp4\"",
            "ERROR: [youtube] x: Video unavailable",
            "",
        ])
    func rejects(line: String) {
        #expect(ProgressParser.parse(line) == nil)
    }

    @Test(
        "detects postprocess phase lines",
        arguments: [
            ("[Merger] Merging formats into \"/tmp/f.mp4\"", true),
            ("[ExtractAudio] Destination: /tmp/f.m4a", true),
            ("[Metadata] Adding metadata to \"/tmp/f.mp4\"", true),
            ("[EmbedSubtitle] Embedding subtitles", true),
            ("[download] 100% of x", false),
            ("[youtube] R00Tgpx36l8: Downloading webpage", false),
        ])
    func postprocess(line: String, expected: Bool) {
        #expect(ProgressParser.isPostprocessLine(line) == expected)
    }

    @Test("filepath lines from --print after_move:filepath")
    func filepath() {
        #expect(ProgressParser.isFilepathLine("/tmp/dir/f [id].mp4"))
        #expect(!ProgressParser.isFilepathLine("[download] /x"))
        #expect(!ProgressParser.isFilepathLine("  3.3%|x|y|z"))
    }

    @Test(
        "classifies real captured yt-dlp output lines",
        arguments: [
            (
                "[youtube] ce0XCrEvgI4: Downloading webpage",
                ParsedLineKind.preparing(detail: "Downloading webpage")
            ),
            (
                "[youtube] [jsc:deno] Solving JS challenges using deno",
                ParsedLineKind.preparing(
                    detail: "Solving JS challenges using deno")
            ),
            (
                "[youtube] ce0XCrEvgI4: Downloading m3u8 information",
                ParsedLineKind.preparing(
                    detail: "Downloading m3u8 information")
            ),
            (
                "[youtube] Extracting URL: https://youtu.be/x",
                ParsedLineKind.preparing(detail: "Extracting URL")
            ),
            (
                "[info] ce0XCrEvgI4: Downloading 1 format(s): 398+251",
                ParsedLineKind.fetchingFormats(expectedStreams: 2)
            ),
            (
                "[info] ce0XCrEvgI4: Downloading 1 format(s): 251",
                ParsedLineKind.fetchingFormats(expectedStreams: 1)
            ),
            (
                "[download] Destination: /Users/x/INDIA'S GOT LATENT...f398.mp4",
                ParsedLineKind.destination(
                    path: "/Users/x/INDIA'S GOT LATENT...f398.mp4")
            ),
            (
                "[download] 100% of   357.15MiB in 00:02:03 at 2.89MiB/s",
                ParsedLineKind.streamPercent(100)
            ),
            (
                "[download]  45.5% of ~  10.00MiB",
                ParsedLineKind.streamPercent(45.5)
            ),
            (
                "[download] /tmp/x.mp4 has already been downloaded",
                ParsedLineKind.alreadyDownloaded
            ),
            (
                "[Merger] Merging formats into \"/tmp/x.mp4\"",
                ParsedLineKind.merging
            ),
            (
                "[ExtractAudio] Destination: /tmp/x.m4a",
                ParsedLineKind.postprocess
            ),
            (
                "/tmp/final [id].mp4",
                ParsedLineKind.filepath("/tmp/final [id].mp4")
            ),
            (
                "ERROR: [youtube] x: Video unavailable",
                ParsedLineKind.ignored
            ),
        ])
    func classify(line: String, expected: ParsedLineKind) {
        #expect(ProgressParser.classify(line) == expected)
    }

    @Test("template progress lines still classify as progress")
    func classifyProgress() {
        let line = "  3.3%| 399.45KiB/s|03:11|  77.18MiB"
        let expected = ProgressUpdate(
            percent: 3.3, speed: "399.45KiB/s",
            eta: "03:11", total: "77.18MiB")
        #expect(ProgressParser.classify(line) == .progress(expected))
    }
}

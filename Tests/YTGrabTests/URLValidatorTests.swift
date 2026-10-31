import Testing

@testable import YTGrab

@Suite("URLValidator — video URLs")
struct VideoURLValidatorTests {
    @Test(
        "accepts canonical https video URLs",
        arguments: [
            "https://www.youtube.com/watch?v=R00Tgpx36l8",
            "https://youtube.com/watch?v=R00Tgpx36l8",
            "https://m.youtube.com/watch?v=R00Tgpx36l8",
            "https://music.youtube.com/watch?v=R00Tgpx36l8",
            "https://youtu.be/R00Tgpx36l8",
            "https://www.youtube.com/shorts/R00Tgpx36l8",
            "https://www.youtube.com/watch?v=R00Tgpx36l8&ab_channel=x",
        ])
    func acceptsVideo(url: String) throws {
        #expect(try URLValidator.validateVideoURL(url) == url)
    }

    @Test(
        "rejects unsafe video URLs",
        arguments: [
            "http://www.youtube.com/watch?v=R00Tgpx36l8",  // http
            "https://vimeo.com/12345",  // other host
            "https://youtube.com.evil.com/watch?v=R00Tgpx36l8",  // suffix host
            "https://youtube.com@evil.com/watch?v=x",  // userinfo
            "https://user:pass@youtube.com/watch?v=R00Tgpx36l8",  // userinfo
            "--exec=rm -rf /",  // option-like
            "-f best https://youtube.com/watch?v=x",  // leading dash
            " https://www.youtube.com/watch?v=R00Tgpx36l8 y",  // whitespace inside
            "https://youtube.com/watch?v=R00Tgpx36l8\n--exec x",  // control char
            "javascript:alert(1)",
            "ftp://youtube.com/x",
            "",
        ])
    func rejectsVideo(url: String) {
        #expect(throws: ValidationError.self) {
            try URLValidator.validateVideoURL(url)
        }
    }
}

@Suite("URLValidator — browse URLs")
struct BrowseURLValidatorTests {
    @Test(
        "accepts channel and listing shapes",
        arguments: [
            "https://www.youtube.com/@LatentX",
            "https://www.youtube.com/@LatentX/videos",
            "https://www.youtube.com/@LatentX/shorts",
            "https://www.youtube.com/@LatentX/streams",
            "https://www.youtube.com/channel/UCAov2BBv1ZJav0c_yHEciAw",
            "https://www.youtube.com/channel/UCAov2BBv1ZJav0c_yHEciAw/videos",
            "https://www.youtube.com/c/somechannel",
            "https://www.youtube.com/c/somechannel/videos",
            "https://www.youtube.com/user/someuser",
            "https://www.youtube.com/playlist?list=PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf",
            "https://www.youtube.com/watch?v=R00Tgpx36l8",
            "https://youtu.be/R00Tgpx36l8",
        ])
    func acceptsBrowse(url: String) throws {
        #expect(try URLValidator.validateBrowseURL(url).hasPrefix("https://"))
    }

    @Test(
        "rejects hostile browse URLs",
        arguments: [
            "https://www.youtube.com/redirect?q=evil.com",
            "https://www.youtube.com//evil.com",
            "https://www.youtube.com/%2e%2e/etc",
            "https://www.youtube.com/../etc",
            "https://youtube.com.evil.com/@handle",
            "https://youtube.com@evil.com/@handle",
            "http://www.youtube.com/@handle",
            "https://www.youtube.com/@handle/admin",
            "https://www.youtube.com/@handle/videos/extra",
            "https://www.youtube.com/playlist?list=x&foo=bar",  // bad query key
            "https://www.youtube.com/watch?v=R00Tgpx36l8&redirect=1",
            "https://www.youtube.com/watch",  // missing v
            "https://www.youtube.com/playlist",  // missing list
            "https://youtu.be/not_a_valid_id",
            "https://www.youtube.com/feed/trending",
        ])
    func rejectsBrowse(url: String) {
        #expect(throws: ValidationError.self) {
            try URLValidator.validateBrowseURL(url)
        }
    }

    @Test("bare @handle normalizes to /videos")
    func bareHandle() throws {
        let target = try URLValidator.classify("@LatentX")
        #expect(target == .url("https://www.youtube.com/@LatentX/videos"))
    }

    @Test("channel URL without tab normalizes to /videos")
    func bareChannel() throws {
        let out = try URLValidator.validateBrowseURL(
            "https://www.youtube.com/channel/UCAov2BBv1ZJav0c_yHEciAw")
        #expect(out == "https://www.youtube.com/channel/UCAov2BBv1ZJav0c_yHEciAw/videos")
    }

    @Test("host without scheme is treated as URL")
    func hostNoScheme() throws {
        let target = try URLValidator.classify("youtube.com/@LatentX")
        #expect(target == .url("https://www.youtube.com/@LatentX/videos"))
    }
}

@Suite("URLValidator — search queries")
struct SearchQueryTests {
    @Test("plain text becomes a search target")
    func search() throws {
        #expect(
            try URLValidator.classify("india's got latent")
                == .search("india's got latent"))
    }

    @Test("option-like query stays a search (protected by -- and prefix)")
    func optionLikeQuery() throws {
        let target = try URLValidator.classify("--exec rm -rf")
        #expect(target == .search("--exec rm -rf"))
    }

    @Test("rejects overlong and control-char queries")
    func rejectsBad() {
        #expect(throws: ValidationError.self) {
            try URLValidator.sanitizeSearchQuery(String(repeating: "a", count: 201))
        }
        #expect(throws: ValidationError.self) {
            try URLValidator.sanitizeSearchQuery("ok\u{7}bell")
        }
        #expect(throws: ValidationError.self) {
            try URLValidator.sanitizeSearchQuery("  \t\n ")
        }
    }

    @Test("video id regex")
    func videoID() {
        #expect(URLValidator.isValidVideoID("R00Tgpx36l8"))
        #expect(!URLValidator.isValidVideoID("R00Tgpx36l"))
        #expect(!URLValidator.isValidVideoID("R00Tgpx36l8!"))
        #expect(!URLValidator.isValidVideoID(""))
    }
}

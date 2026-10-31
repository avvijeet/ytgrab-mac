import Testing

@testable import YTGrab

@Suite("SubtitleLangsValidator")
struct SubtitleLangsValidatorTests {
    @Test(
        "accepts valid language lists",
        arguments: [
            "en.*", "en,hi", "-live_chat", "en-US", "all",
            "all,-live_chat", "*", "en.*,ja,-en-AU", "zh-Hant-TW",
        ])
    func accepts(_ langs: String) {
        #expect(SubtitleLangsValidator.isValid(langs))
    }

    @Test(
        "rejects invalid language lists",
        arguments: [
            "en;rm", "", "en,,hi", "en hi", "en rm -rf", "--x",
            "en a,b", "en,*|x", "en:x", "a,a,a,a,a,a,a,a,a,a,a",  // 11 tokens
        ])
    func rejects(_ langs: String) {
        #expect(!SubtitleLangsValidator.isValid(langs))
    }

    @Test("rejects over-length input")
    func tooLong() {
        #expect(
            !SubtitleLangsValidator.isValid(
                String(repeating: "en,", count: 40)))  // 120 chars
        #expect(
            !SubtitleLangsValidator.isValid(
                "this-language-tag-is-way-too-long"))  // 33-char token
    }

    @Test("exactly 10 tokens is allowed")
    func tenTokens() {
        #expect(SubtitleLangsValidator.isValid("a,b,c,d,e,f,g,h,i,j"))
    }
}

import Foundation

/// Validates a `--sub-langs` value. yt-dlp accepts a comma-separated list
/// of language tags (regex allowed) or "all", where a leading "-" marks
/// exclusion (e.g. "all,-live_chat"). We accept a strict safe subset:
/// tokens of [A-Za-z0-9_.*-]{1,20} with at most one leading "-".
enum SubtitleLangsValidator {
    static let maxLength = 100
    static let maxTokens = 10

    /// Returns nil when valid, otherwise a user-facing reason.
    static func error(for raw: String) -> String? {
        if raw.isEmpty { return "Language list is empty" }
        if raw.count > maxLength {
            return "Language list exceeds \(maxLength) characters"
        }
        let tokens = raw.split(separator: ",", omittingEmptySubsequences: false)
        if tokens.isEmpty { return "Language list is empty" }
        if tokens.count > maxTokens {
            return "At most \(maxTokens) languages allowed"
        }
        for token in tokens {
            var token = Substring(token)
            // A single leading "-" marks exclusion (e.g. "-live_chat");
            // a second dash is not a language token.
            if token.hasPrefix("-") { token = token.dropFirst() }
            if token.hasPrefix("-") { return "Illegal token: \(token)" }
            if token.isEmpty { return "Empty language token" }
            if token.count > 20 { return "Language token too long: \(token)" }
            for scalar in token.unicodeScalars where !isAllowed(scalar) {
                return "Illegal character in token: \(token)"
            }
        }
        return nil
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x30...0x39).contains(value)  // 0-9
            || (0x41...0x5A).contains(value)  // A-Z
            || (0x61...0x7A).contains(value)  // a-z
            || value == 0x5F  // _
            || value == 0x2E  // .
            || value == 0x2A  // *
            || value == 0x2D  // -
    }

    static func isValid(_ raw: String) -> Bool { error(for: raw) == nil }
}

import Foundation

/// Filters out common Whisper hallucinations -- phantom phrases produced from
/// silence or very quiet audio. Ported from rust-voice-assist/src/transcribe.rs.
enum HallucinationFilter {

    /// Known hallucination phrases that Whisper produces on silence/near-silence.
    private static let hallucinations: Set<String> = [
        "thank you",
        "thanks",
        "thanks for watching",
        "thank you for watching",
        "okay",
        "ok",
        "bye",
        "goodbye",
        "you",
        "yeah",
        "yes",
        "no",
        "so",
        "the end",
        "hmm",
        "huh",
        "ah",
        "oh",
        "uh",
        "um",
        "subs by www",
        "subtitles by",
        "subscribe",
        "like and subscribe",
    ]

    /// Returns true if the given text matches a known Whisper hallucination pattern.
    /// Strips punctuation and whitespace, then checks against the known set.
    static func isHallucination(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalized.isEmpty {
            return true
        }

        return hallucinations.contains(normalized)
    }
}

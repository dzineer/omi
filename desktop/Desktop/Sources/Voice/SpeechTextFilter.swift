import Foundation

/// Filters AI response text into plain conversational English suitable for TTS.
/// Strips markdown formatting, code blocks, bullet points, tables, links,
/// and other visual formatting that sounds unnatural when spoken aloud.
enum SpeechTextFilter {

    /// Convert AI response text into speakable plain English.
    static func filterForSpeech(_ text: String) -> String {
        var result = text

        // Remove code blocks (```language ... ```)
        result = result.replacingOccurrences(
            of: "```[\\s\\S]*?```",
            with: " I've included some code for that. ",
            options: .regularExpression
        )

        // Remove inline code (`code`)
        result = result.replacingOccurrences(
            of: "`([^`]+)`",
            with: "$1",
            options: .regularExpression
        )

        // Remove markdown headers (# ## ### etc)
        result = result.replacingOccurrences(
            of: "(?m)^#{1,6}\\s*",
            with: "",
            options: .regularExpression
        )

        // Remove bold (**text** or __text__)
        result = result.replacingOccurrences(
            of: "\\*\\*([^*]+)\\*\\*",
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "__([^_]+)__",
            with: "$1",
            options: .regularExpression
        )

        // Remove italic (*text* or _text_) — careful not to match bold
        result = result.replacingOccurrences(
            of: "(?<!\\*)\\*([^*]+)\\*(?!\\*)",
            with: "$1",
            options: .regularExpression
        )

        // Remove strikethrough (~~text~~)
        result = result.replacingOccurrences(
            of: "~~([^~]+)~~",
            with: "$1",
            options: .regularExpression
        )

        // Remove markdown links [text](url) -> just text
        result = result.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\([^)]+\\)",
            with: "$1",
            options: .regularExpression
        )

        // Remove bare URLs
        result = result.replacingOccurrences(
            of: "https?://\\S+",
            with: "",
            options: .regularExpression
        )

        // Convert bullet points (- or * or numbered) to natural speech
        result = result.replacingOccurrences(
            of: "(?m)^\\s*[-*]\\s+",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(?m)^\\s*\\d+\\.\\s+",
            with: "",
            options: .regularExpression
        )

        // Remove markdown tables (| col | col |)
        result = result.replacingOccurrences(
            of: "(?m)^\\|.*\\|\\s*$",
            with: "",
            options: .regularExpression
        )
        // Remove table separator lines (|---|---|)
        result = result.replacingOccurrences(
            of: "(?m)^\\|[-:| ]+\\|\\s*$",
            with: "",
            options: .regularExpression
        )

        // Remove horizontal rules (--- or ***)
        result = result.replacingOccurrences(
            of: "(?m)^[-*]{3,}\\s*$",
            with: "",
            options: .regularExpression
        )

        // Remove HTML tags
        result = result.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        // Remove image markdown ![alt](url)
        result = result.replacingOccurrences(
            of: "!\\[[^\\]]*\\]\\([^)]+\\)",
            with: "",
            options: .regularExpression
        )

        // Remove emoji shortcodes (:emoji:)
        result = result.replacingOccurrences(
            of: ":[a-z_]+:",
            with: "",
            options: .regularExpression
        )

        // Remove blockquotes (> text) — must come before newline collapse
        result = result.replacingOccurrences(
            of: "(?m)^>\\s*",
            with: "",
            options: .regularExpression
        )

        // Replace "Here's a quick example:" + code replacement with natural phrasing
        result = result.replacingOccurrences(
            of: "(?i)here'?s?\\s+(a\\s+)?(quick\\s+)?example:?\\s*I've included some code for that\\.",
            with: "I've included some code for that.",
            options: .regularExpression
        )

        // Collapse multiple newlines into period + space
        result = result.replacingOccurrences(
            of: "\\n{2,}",
            with: ". ",
            options: .regularExpression
        )

        // Replace single newlines with space
        result = result.replacingOccurrences(of: "\n", with: " ")

        // Collapse multiple spaces
        result = result.replacingOccurrences(
            of: "\\s{2,}",
            with: " ",
            options: .regularExpression
        )

        // Clean up orphaned punctuation from removals
        result = result.replacingOccurrences(
            of: "\\s+([.,;:!?])",
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "([.!?])\\s*([.!?])",
            with: "$1",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

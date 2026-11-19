import Foundation

/// Rough, dependency-free estimate of how many text-encoder tokens a prompt will
/// consume. The real tokenizer (FLUX.2 → Qwen3 BPE) lives in the Python backend,
/// so this is a deliberately conservative heuristic for live UI feedback, not an
/// exact count.
///
/// English BPE averages roughly 1.3 tokens per word and about 1 token per 4
/// characters. We take the larger of the two estimates so the counter errs toward
/// warning early rather than letting a prompt silently overrun the cap (past which
/// the backend truncates and trailing text is dropped before reaching the model).
///
/// CJK ideographs, kana and hangul are written without spaces and encode at about
/// one token per character, so they are counted one each and removed from the text
/// before the word/character estimate runs on what is left.
nonisolated enum PromptTokenEstimator {
    static func estimate(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        var dense = 0
        var rest = String.UnicodeScalarView()
        for scalar in trimmed.unicodeScalars {
            if isDense(scalar) {
                dense += 1
                // One space per dense run keeps the words on either side apart
                // without adding a counted character per dense scalar.
                if rest.last != " " {
                    rest.append(" ")
                }
            } else {
                rest.append(scalar)
            }
        }
        let other = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !other.isEmpty else { return dense }
        let words = other.split(whereSeparator: \.isWhitespace).count
        let chars = other.count
        let byWords = Int((Double(words) * 1.3).rounded())
        let byChars = Int((Double(chars) / 4.0).rounded(.up))
        return dense + max(byWords, byChars)
    }

    /// Scripts the BPE encodes at roughly one token per scalar.
    private static func isDense(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040 ... 0x30FF, // Hiragana, Katakana
             0x31F0 ... 0x31FF, // Katakana phonetic extensions
             0x3400 ... 0x4DBF, // CJK Extension A
             0x4E00 ... 0x9FFF, // CJK Unified Ideographs
             0xF900 ... 0xFAFF, // CJK Compatibility Ideographs
             0xFF66 ... 0xFF9F, // Half-width Katakana
             0x1100 ... 0x11FF, // Hangul Jamo
             0x3130 ... 0x318F, // Hangul Compatibility Jamo
             0xAC00 ... 0xD7AF, // Hangul Syllables
             0x20000 ... 0x2FA1F: // CJK Extensions B–F, Compatibility Supplement
            true
        default:
            false
        }
    }
}

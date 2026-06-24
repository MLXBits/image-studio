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
enum PromptTokenEstimator {
    static func estimate(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let words = trimmed.split(whereSeparator: \.isWhitespace).count
        let chars = trimmed.count
        let byWords = Int((Double(words) * 1.3).rounded())
        let byChars = Int((Double(chars) / 4.0).rounded(.up))
        return max(byWords, byChars)
    }
}

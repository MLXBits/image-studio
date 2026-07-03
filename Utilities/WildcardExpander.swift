import Foundation

/// Expands `{option one|option two|option three}` alternation groups in a
/// prompt into a batch of resolved variants using **independent sampling**:
///
/// - The batch size defaults to the largest group's option count
///   (``variantCount(_:)``), so the biggest single dimension is fully walked.
/// - The largest group is *covered* — each of its options appears once across
///   the batch (in a freshly shuffled order per call).
/// - Every other group is sampled independently per job, so combinations vary
///   instead of moving in lockstep.
/// - Combinations are spread apart: each new job prefers to differ from every
///   previous one in at least two groups (best-effort), so a batch avoids
///   near-identical prompts that differ in only a single detail — not just
///   exact duplicates.
///
/// Each call draws from the supplied RNG, so re-running reshuffles the
/// pairings. A brace group only counts as a wildcard when it contains `|` and
/// no nested `{` — plain braces (e.g. JSON fragments) pass through verbatim.
/// No nesting or escaping (v1).
enum WildcardExpander {
    /// True when `text` has at least one expandable `{a|b}` group.
    static func containsWildcards(_ text: String) -> Bool {
        variantCount(text) > 1
    }

    /// The natural batch size: the option count of the largest wildcard group,
    /// or 1 when there are none.
    static func variantCount(_ text: String) -> Int {
        optionGroups(text).map(\.count).max() ?? 1
    }

    /// `count` resolved variants of `text` (see the type doc for the sampling
    /// rules). Draws from the system RNG — call again for a fresh shuffle.
    static func expandVariants(_ text: String, count: Int) -> [String] {
        var rng = SystemRandomNumberGenerator()
        return expandVariants(text, count: count, using: &rng)
    }

    /// Deterministic variant for tests / seeded runs.
    static func expandVariants(_ text: String, count: Int, using rng: inout some RandomNumberGenerator) -> [String] {
        guard count > 0 else { return [] }
        let groups = optionGroups(text)
        guard !groups.isEmpty else { return Array(repeating: text, count: count) }

        // Cover the largest group: a shuffled permutation of its option indices,
        // one per job for the first `size` jobs.
        let largest = groups.indices.max { groups[$0].count < groups[$1].count } ?? 0
        var coverage = Array(0 ..< groups[largest].count)
        coverage.shuffle(using: &rng)

        // Prefer each combination to differ from all prior picks in at least
        // this many groups, so batches don't come back near-identical (only
        // achievable when the option space is large enough; best-effort).
        let target = min(2, groups.count)

        var chosen: [[Int]] = []
        for i in 0 ..< count {
            var best: [Int] = []
            var bestScore = -1
            // Draw several candidates; keep the one most different from every
            // previous pick, stopping early once it clears the target spread.
            for _ in 0 ..< 24 {
                let candidate = groups.indices.map { group in
                    if group == largest, i < coverage.count { return coverage[i] }
                    return Int.random(in: 0 ..< groups[group].count, using: &rng)
                }
                let score = chosen.map { distance($0, candidate) }.min() ?? Int.max
                if score > bestScore {
                    bestScore = score
                    best = candidate
                }
                if score >= target { break }
            }
            chosen.append(best)
        }
        return chosen.map { substitute(text, choices: $0) }
    }

    /// Number of groups whose chosen option differs between two combinations.
    private static func distance(_ lhs: [Int], _ rhs: [Int]) -> Int {
        zip(lhs, rhs).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
    }

    // MARK: - Private

    /// The options of every valid `{a|b|…}` group, in order of appearance.
    private static func optionGroups(_ text: String) -> [[String]] {
        var groups: [[String]] = []
        scan(text) { options in
            groups.append(options)
            return nil // collect only — leave the group in place
        }
        return groups
    }

    /// Replaces the k-th group with its chosen option (`choices[k]`).
    private static func substitute(_ text: String, choices: [Int]) -> String {
        var index = 0
        return scan(text) { options in
            defer { index += 1 }
            guard index < choices.count, choices[index] < options.count else { return options.first }
            return options[choices[index]]
        }
    }

    /// Walks `text` once, invoking `resolve` for each valid wildcard group's
    /// options. A non-nil return replaces the group; nil keeps it verbatim.
    /// Returns the rewritten text.
    @discardableResult
    private static func scan(_ text: String, resolve: ([String]) -> String?) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "{", let close = text[index...].firstIndex(of: "}") {
                let inner = text[text.index(after: index) ..< close]
                if inner.contains("|"), !inner.contains("{") {
                    let options = inner.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                    if let replacement = resolve(options) {
                        result += replacement
                        index = text.index(after: close)
                        continue
                    }
                }
            }
            result.append(char)
            index = text.index(after: index)
        }
        return result
    }
}

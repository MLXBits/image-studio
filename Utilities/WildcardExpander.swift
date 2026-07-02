import Foundation

/// Expands `{option one|option two|option three}` alternation groups in a
/// prompt deterministically: variant `i` resolves every group to its
/// `i mod count`-th option, so a batch walks the options in order instead of
/// sampling randomly (guaranteed coverage, no duplicate draws). Groups with
/// different sizes cycle to fit; the natural batch size is
/// ``variantCount(_:)`` — the largest group — capped by the caller.
///
/// A brace group only counts as a wildcard when it contains `|` and no nested
/// `{` — plain braces (e.g. JSON fragments) pass through verbatim. No nesting
/// or escaping (v1).
enum WildcardExpander {
    /// True when `text` has at least one expandable `{a|b}` group.
    static func containsWildcards(_ text: String) -> Bool {
        variantCount(text) > 1
    }

    /// The number of distinct variants `text` naturally expands to: the
    /// option count of its largest wildcard group, or 1 when there are none.
    static func variantCount(_ text: String) -> Int {
        var count = 1
        scan(text) { options in
            count = max(count, options.count)
            return nil // counting only — leave the group in place
        }
        return count
    }

    /// Variant `index` of the prompt: every group resolves to its
    /// `index mod count`-th option.
    static func expandVariant(_ text: String, index: Int) -> String {
        scan(text) { options in
            options[index % options.count]
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

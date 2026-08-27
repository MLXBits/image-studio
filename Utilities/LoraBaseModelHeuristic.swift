import Foundation

// MARK: - LoRA base-model heuristic
//
// When a ComfyUI server exposes its LoRAs via `/models/loras`, the names are *relative paths* with a
// subfolder prefix when present (e.g. `krea2/Krea2-realism-V2.safetensors`) and bare basenames for
// top-level files (e.g. `minimax_h3_turbo_4step_v0.1.safetensors`). The server does NOT tell us which
// base model a LoRA was trained against — no endpoint on ComfyUI 0.33 exposes that metadata, and there's
// no Manager to add one. So we infer it from naming conventions: the *subfolder* name is the strongest
// signal (a file under `krea2/` was deliberately placed by its owner for Krea 2), followed by distinctive
// tokens in the basename (`qwen`, `krea`, …).
//
/// The result of scoring one server LoRA against every generative family's signature.
enum LoraBaseModelGuess: Equatable {
    /// A confident match to exactly one of our image families — safe to auto-catalog under it.
    case matched(ModelFamily)
    /// No family scored high enough, or several tied — the user should classify this LoRA by hand before
    /// relying on its default strength/tags. Surfaces in an "Unclassified" group rather than being forced
    /// onto a wrong base model.
    case unclassified

    var family: ModelFamily? {
        if case let .matched(f) = self {
            return f
        }
        return nil
    }

    var isMatched: Bool {
        if case .matched = self {
            return true
        }
        return false
    }
}

/// Pure, side-effect-free scorer for a single server LoRA name. Lives here (not in ``ComfyUIClient`` or the
/// store) so it's unit-testable without any UI/network dependency and reusable wherever we need to map a raw
/// filename to a family — auto-cataloging on discovery *and* the "reclassify" action if the user wants to
/// re-derive a guess later.
enum LoraBaseModelHeuristic {
    /// Per-family token signatures, most-specific first. A name *matches* a family when its **subfolder**
    /// component contains one of that folder's tokens (the strongest signal — deliberate placement), or when the
    /// whole lowercased relative path contains a distinctive basename token for some family with no competing
    /// match from another family at equal-or-higher specificity.
    ///
    /// Order matters: more specific / rarer tokens are listed before generic ones so a name containing both
    /// `krea` and, say, a shared suffix still lands on the intended family. Token lists are lowercase; matching
    /// is case-insensitive substring against the lowercased relative path (subfolder included), which correctly
    /// handles both flat basenames and `krea2/foo.safetensors`.
    static let signatures: [(family: ModelFamily, tokens: [String])] = [
        (.flux, ["flax", "flux1", "flux-2", "flux_2", "flick", "a-pix"]),
        (.ideogram4, ["ideogram", "ido"]),
        (.krea2, ["qwen-image", "krea2", "krea_2", "krea 2", "krea2-realism", "krea"]),
        (.zimage, ["zimage-turbo", "z-image", "z_image", "zi_turbo"]),
    ]

    /// Score `name` (a server `/models/loras` entry — relative path or bare basename) and return the best-guess
    /// family. Returns `.matched(_)` only when a single family wins decisively; `.unclassified` otherwise.
    ///
    /// - Parameter name: exactly the string `/models/loras` returned, e.g. `krea2/Krea2-realism-V2.safetensors`.
    static func guess(for name: String) -> LoraBaseModelGuess {
        let lowered = name.lowercased()

        // 1. Subfolder is the strongest signal — if it names a known family, that's decisive on its own.
        let folder = subfolder(of: lowered)
        if !folder.isEmpty {
            for (family, tokens) in signatures where matchesAny(folder, tokens) {
                return .matched(family)
            }
        }

        // 2. Otherwise score the whole path by how many of each family's distinctive tokens appear. The first
        //    (most-specific) family with any hit wins; ties are impossible because we iterate in specificity
        //    order and take the first positive, so a name hitting both `krea` and another family's token still
        //    lands on whichever family is listed first among those it matched.
        for (family, tokens) in signatures where matchesAny(lowered, tokens) {
            return .matched(family)
        }

        return .unclassified
    }

    /// The leading `sub/` component of a relative path, lowercased and with the trailing slash stripped. Empty
    /// for a top-level (flat) file. Example: `krea2/foo.safetensors` → `"krea2"`; `foo.safetensors` → ``.
    static func subfolder(of relativePath: String) -> String {
        guard let slash = relativePath.firstIndex(of: "/") else { return "" }
        let head = relativePath[relativePath.startIndex ..< slash]
        return String(head).trimmingCharacters(in: .whitespaces)
    }

    private static func matchesAny(_ haystack: String, _ tokens: [String]) -> Bool {
        tokens.contains { token in
            !token.isEmpty && haystack.range(of: token, options: .caseInsensitive) != nil
        }
    }
}

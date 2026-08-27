@testable import MLXBits_Image_Studio
import Testing

/// Tests for ``LoraBaseModelHeuristic``, grounded in the *real* `/models/loras` list from a live ComfyUI 0.33 box:
/// 29 files under a `krea2/` subfolder, plus ~28 flat video-model LoRAs (Minimax H3 / LTX) and a few other bases.
/// The point of this heuristic is to auto-catalog the Krea 2 ones correctly while *not* force-fitting the video-only
/// ones onto an image family — so both directions are exercised with actual filenames, not synthetic ones.
@Suite("LoraBaseModelHeuristic")
struct LoraBaseModelHeuristicTests {
    @Test func krea2SubfolderIsDecisive() {
        // Files under the krea2/ subfolder match on the folder name alone, regardless of basename content.
        #expect(LoraBaseModelHeuristic.guess(for: "krea2/Krea2-realism-V2.safetensors") == .matched(.krea2))
        #expect(LoraBaseModelHeuristic.guess(for: "krea2/Afterlight_v1.safetensors") == .matched(.krea2))
        // Even a basename with no recognizable token still lands on krea2 because of the folder placement.
        #expect(LoraBaseModelHeuristic.guess(for: "krea2/pytorch_lora_weights.safetensors") == .matched(.krea2))
    }

    @Test func flatKrea2TokensMatchByBasename() {
        // A Krea 2 LoRA sitting at the top level (no subfolder) is still recognized by its distinctive tokens.
        #expect(LoraBaseModelHeuristic.guess(for: "krea2_nsfw_v4.safetensors") == .matched(.krea2))
        #expect(LoraBaseModelHeuristic.guess(for: "MysticXXX_KREA2_v3.safetensors") == .matched(.krea2))
        #expect(LoraBaseModelHeuristic.guess(for: "qwen-image-style.safetensors") == .matched(.krea2))
    }

    @Test func otherFamiliesMatchByTokens() {
        #expect(LoraBaseModelHeuristic.guess(for: "flux1-dev-boost.safetensors") == .matched(.flux))
        #expect(LoraBaseModelHeuristic.guess(for: "ideogram4-detail.safetensors") == .matched(.ideogram4))
        #expect(LoraBaseModelHeuristic.guess(for: "zimage-turbo-skin.safetensors") == .matched(.zimage))
    }

    @Test func videoOnlyLorasAreUnclassified() {
        // The box's flat Minimax/LTX video LoRAs must NOT be force-matched onto an image family — they return
        // `.unclassified` so the UI can surface them for manual classification instead of a wrong guess.
        #expect(LoraBaseModelHeuristic.guess(for: "minimax_h3_turbo_4step_v0.1.safetensors") == .unclassified)
        #expect(LoraBaseModelHeuristic.guess(for: "LTX2.3_DMD_hybrid_v2.safetensors") == .unclassified)
        #expect(LoraBaseModelHeuristic.guess(for: "ltx2.3_upscale_ic-lora_06250.safetensors") == .unclassified)
        // Generic/unknown names also stay unclassified rather than guessing.
        #expect(LoraBaseModelHeuristic.guess(for: "mystery_style_v1.safetensors") == .unclassified)
    }

    @Test func subfolderHelperStripsCorrectly() {
        #expect(LoraBaseModelHeuristic.subfolder(of: "krea2/foo.safetensors") == "krea2")
        #expect(LoraBaseModelHeuristic.subfolder(of: "a/b/c.safetensors") == "a")
        #expect(LoraBaseModelHeuristic.subfolder(of: "flat.safetensors") == "")
    }

    @Test func matchedAccessorRoundTrips() {
        let m = LoraBaseModelGuess.matched(.krea2)
        #expect(m.family == .krea2)
        #expect(m.isMatched)
        let u = LoraBaseModelGuess.unclassified
        #expect(u.family == nil)
        #expect(!u.isMatched)
    }

    @Test func caseInsensitiveMatching() {
        // Names arrive in mixed case from the server; matching must be case-insensitive.
        #expect(LoraBaseModelHeuristic.guess(for: "KREA2/REALISM.safetensors") == .matched(.krea2))
        #expect(LoraBaseModelHeuristic.guess(for: "KREA2_NSFW_v4.SAFETENSORS") == .matched(.krea2))
    }
}

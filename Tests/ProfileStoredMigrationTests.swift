import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Covers `AppSettings.ProfileStored`, the per-profile half of the settings
/// file. Migration decodes the pre-profiles `settings.json` straight into it, so
/// its keys must match the legacy ones and one bad field must not cost the rest.
struct ProfileStoredMigrationTests {
    /// Shape of a pre-profiles `settings.json`: content keys mixed in with
    /// global ones. Dates use JSONEncoder's default (seconds since 2001).
    private let legacySettings = """
    {
      "mfluxBinaryDir": "/opt/mflux/bin",
      "outputDir": "/Users/me/Pictures/MLXBits",
      "comfyURL": "http://comfy-host:8188",
      "defaultBoard": "Portraits",
      "notepadText": "# ideas\\n- fox in snow",
      "lastPrompt": "a red fox",
      "lastScenarioOutline": "rainy alley",
      "lastIdeogramPlainPrompt": "poster",
      "lastIdeogramUsePlainPrompt": true,
      "lastIdeogramSeed": 42,
      "lastKrea2": {"prompt": "krea fox", "board": "Portraits"},
      "lastZImage": {"prompt": "zimage fox"},
      "activeTemplateIDs": ["AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"],
      "promptHistory": [
        {"id": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", "prompt": "a red fox",
         "lastUsedAt": 800000000, "useCount": 2, "pinned": true}
      ]
    }
    """

    private func decode(_ json: String) throws -> AppSettings.ProfileStored {
        try JSONDecoder().decode(AppSettings.ProfileStored.self, from: Data(json.utf8))
    }

    @Test func legacySettingsYieldTheContentFields() throws {
        let stored = try decode(legacySettings)
        #expect(stored.defaultBoard == "Portraits")
        #expect(stored.notepadText == "# ideas\n- fox in snow")
        #expect(stored.lastPrompt == "a red fox")
        #expect(stored.lastScenarioOutline == "rainy alley")
        #expect(stored.lastIdeogramPlainPrompt == "poster")
        #expect(stored.lastIdeogramUsePlainPrompt == true)
        #expect(stored.lastIdeogramSeed == 42)
        #expect(stored.lastKrea2?.prompt == "krea fox")
        #expect(stored.lastZImage?.prompt == "zimage fox")
        #expect(stored.promptHistory?.first?.prompt == "a red fox")
        #expect(stored.promptHistory?.first?.pinned == true)
        #expect(try stored.resolvedActiveTemplateIDs == [#require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))])
    }

    /// One malformed entry (here: history as a string) must not lose the
    /// notepad — the synthesized decoder would throw and drop everything.
    @Test func malformedFieldKeepsTheOthers() throws {
        let stored = try decode("""
        {"notepadText": "keep me", "promptHistory": "oops", "lastIdeogramSeed": "x", "lastPrompt": "still here"}
        """)
        #expect(stored.notepadText == "keep me")
        #expect(stored.lastPrompt == "still here")
        #expect(stored.promptHistory == nil)
        #expect(stored.lastIdeogramSeed == nil)
    }

    /// Settings written before multi-select stored a single `activeTemplateID`.
    @Test func legacySingleTemplateIDBecomesASelection() throws {
        let stored = try decode(#"{"activeTemplateID": "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"}"#)
        #expect(try stored.resolvedActiveTemplateIDs == [#require(UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"))])
    }

    @Test func arraySelectionWinsOverLegacySingleID() throws {
        let stored = try decode("""
        {"activeTemplateID": "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", "activeTemplateIDs": []}
        """)
        #expect(stored.resolvedActiveTemplateIDs.isEmpty)
    }

    /// The hand-written decoder and the synthesized encoder must agree on keys,
    /// or a profile's notepad would be written under a name it can't read back.
    @Test func encodeThenDecodeRoundTrips() throws {
        var stored = AppSettings.ProfileStored()
        stored.notepadText = "round trip"
        stored.galleryCollapsedBoards = ["Old", "Drafts"]
        stored.lastLoras = []
        stored.promptHistory = [
            PromptHistoryEntry(prompt: "p", lastUsedAt: Date(timeIntervalSinceReferenceDate: 1)),
        ]
        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(AppSettings.ProfileStored.self, from: data)
        #expect(decoded.notepadText == "round trip")
        #expect(decoded.galleryCollapsedBoards == ["Old", "Drafts"])
        #expect(decoded.promptHistory?.first?.prompt == "p")
        #expect(decoded.lastLoras == [])
    }
}

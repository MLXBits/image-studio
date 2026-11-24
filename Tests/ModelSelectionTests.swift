@testable import MLXBits_Image_Studio
import Testing

/// The model button's pure logic: the warm-driver identity, the halo, the second line and
/// the chevron menu.
struct ModelSelectionTests {
    /// The chevron menu's sections in the tests below.
    private let sections = [
        ModelSection(title: "Krea", models: [.krea2]),
        ModelSection(title: "Z-Image", models: [.zimageTurbo, .zimage]),
    ]

    // MARK: - Identity

    @Test func aPrecisionChangeIsAModelChange() {
        let q8 = ModelSelection(variant: .krea2, quantize: 8)
        let q4 = ModelSelection(variant: .krea2, quantize: 4)
        #expect(q8.key != q4.key)
        #expect(q8.key == ModelSelection(variant: .krea2, quantize: 8).key)
    }

    @Test func aCustomCheckpointIsKeyedByRepoAndTargetNotPrecision() {
        let tune = ModelSelection(variant: .krea2, quantize: 8, customRepo: " org/tune ")
        #expect(tune.isCustom)
        #expect(tune.customRepo == "org/tune")
        #expect(tune.key == ModelSelection(variant: .krea2, quantize: 4, customRepo: "org/tune").key)
        #expect(tune.key != ModelSelection(variant: .krea2, quantize: 8, customRepo: "org/other").key)
        #expect(tune.key != ModelSelection(variant: .flux2Klein9B, quantize: 8, customRepo: "org/tune").key)
        #expect(tune.key != ModelSelection(variant: .krea2, quantize: 8).key)
    }

    @Test func pickingCustomWithoutARepoSelectsItsTarget() {
        let picked = ModelSelection.picked(.custom, quantize: 8, customRepo: "  ", customBase: .krea2)
        #expect(picked == ModelSelection(variant: .krea2, quantize: 8))
        let builtIn = ModelSelection.picked(.zimage, quantize: 4, customRepo: "org/tune", customBase: .krea2)
        #expect(builtIn == ModelSelection(variant: .zimage, quantize: 4))
    }

    @Test func theShortNameIsTheLastPathComponent() {
        #expect(ModelSelection.shortName(of: "my-org/my-finetune") == "my-finetune")
        #expect(ModelSelection.shortName(of: "/Users/me/models/tune ") == "tune")
        #expect(ModelSelection.shortName(of: "tune") == "tune")
    }

    // MARK: - Halo

    @Test func theHaloGlowsOnlyForTheSelectedModel() {
        #expect(WarmHalo.of(selection: "a", loaded: "a", loading: nil) == .warm)
        #expect(WarmHalo.of(selection: "a", loaded: "b", loading: nil) == .cold)
        #expect(WarmHalo.of(selection: "a", loaded: nil, loading: "a") == .loading)
        #expect(WarmHalo.of(selection: "a", loaded: "b", loading: "a") == .loading)
        #expect(WarmHalo.of(selection: "a", loaded: nil, loading: "b") == .cold)
    }

    @Test func theHaloIsOffWhenTheFamilyRunsOnComfyUI() {
        #expect(WarmHalo.of(selection: nil, loaded: "a", loading: nil) == .cold)
    }

    // MARK: - Caption

    private func input(
        override: String? = nil, custom: String? = nil, ramGB: Double = 22, downloadGB: Double? = nil, warmGB: Double? = nil
    ) -> ModelButtonCaption.Input {
        .init(
            quantLabel: "Q8", overrideRepo: override, customLoadsAs: custom,
            ramGB: ramGB, fit: .comfortable, downloadGB: downloadGB, warmGB: warmGB
        )
    }

    @Test func aColdCachedModelShowsItsRAM() {
        #expect(ModelButtonCaption.segments(for: input()) == [
            .init(text: "Q8"),
            .init(text: "≈22 GB RAM", tone: .fit(.comfortable)),
        ])
    }

    @Test func aModelToDownloadShowsItsSize() {
        let segments = ModelButtonCaption.segments(for: input(downloadGB: 21.6))
        #expect(segments.last == .init(text: "22 GB", systemImage: "arrow.down.circle"))
        #expect(segments.count == 3)
    }

    @Test func aWarmModelShowsItsMeasuredMemory() {
        #expect(ModelButtonCaption.segments(for: input(downloadGB: 22, warmGB: 21.34)) == [
            .init(text: "Q8"),
            .init(text: "21.3 GB warm"),
        ])
    }

    @Test func anOverrideOrCustomCheckpointReplacesThePrecision() {
        #expect(ModelButtonCaption.segments(for: input(override: "org/repo")) == [
            .init(text: "Override · org/repo", systemImage: "gearshape"),
        ])
        #expect(ModelButtonCaption.segments(for: input(custom: "Krea 2 Turbo")) == [
            .init(text: "loads as Krea 2 Turbo"),
        ])
    }

    @Test func anUnknownRAMNeedIsLeftOut() {
        #expect(ModelButtonCaption.segments(for: input(ramGB: 0)) == [.init(text: "Q8")])
    }

    // MARK: - Chevron menu

    private func row(_ model: FluxModelVariant, cached: Set<Int>, toolMissing: Bool = false) -> ModelRow {
        ModelInventory.row(
            for: model, isCached: { cached.contains($0) }, ramGB: { _ in 10 }, physicalGB: 64, toolMissing: toolMissing
        )
    }

    @Test func theMenuListsDownloadedPairsBySection() {
        let groups = ModelSwitchMenu.groups(
            sections: sections,
            rows: [.krea2: row(.krea2, cached: [8, 4]), .zimageTurbo: row(.zimageTurbo, cached: [0]), .zimage: row(.zimage, cached: [])],
            current: ModelSelection(variant: .krea2, quantize: 4),
            overridden: []
        )
        #expect(groups.map { $0.map(\.title) } == [["Krea 2 Turbo · Q8", "Krea 2 Turbo · Q4"], ["Z-Image Turbo · BF16"]])
        #expect(groups[0].map(\.isCurrent) == [false, true])
    }

    @Test func theCurrentPairIsListedEvenWhenNotDownloaded() {
        let groups = ModelSwitchMenu.groups(
            sections: sections, rows: [.krea2: row(.krea2, cached: [])],
            current: ModelSelection(variant: .krea2, quantize: 8), overridden: []
        )
        #expect(groups.map { $0.map(\.title) } == [["Krea 2 Turbo · Q8"]])
        #expect(groups[0][0].isCurrent)
    }

    @Test func nothingDownloadedAndACustomSelectionGivesAnEmptyMenu() {
        let groups = ModelSwitchMenu.groups(
            sections: sections, rows: [.krea2: row(.krea2, cached: [])], current: nil, overridden: []
        )
        #expect(groups.isEmpty)
    }

    @Test func aModelMissingFromMfluxIsDisabledUnlessItIsCurrent() {
        let rows = [FluxModelVariant.krea2: row(.krea2, cached: [8], toolMissing: true)]
        let other = ModelSwitchMenu.groups(
            sections: sections, rows: rows, current: ModelSelection(variant: .zimage, quantize: 8), overridden: []
        )
        #expect(other[0][0].unavailableNote == "not in this mflux install")
        let current = ModelSwitchMenu.groups(
            sections: sections, rows: rows, current: ModelSelection(variant: .krea2, quantize: 8), overridden: []
        )
        #expect(current[0][0].unavailableNote == nil)
    }

    @Test func anOverriddenModelIsOneRowWithoutAPrecision() {
        let groups = ModelSwitchMenu.groups(
            sections: sections, rows: [.krea2: row(.krea2, cached: [0, 8, 4])],
            current: ModelSelection(variant: .krea2, quantize: 8), overridden: [.krea2]
        )
        #expect(groups.map { $0.map(\.title) } == [["Krea 2 Turbo · Override"]])
        #expect(groups[0][0].quantize == nil)
        #expect(groups[0][0].isCurrent)
    }
}

# Issue #83 Performance Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the two performance items from the 2026-11-04 audit (issue #83, "Performance" section): (1) gallery search rebuilds every haystack and evaluates `gallerySections` twice per body pass; (2) `canReach` file checks run on the main thread (App Store build).

**Architecture:** Task 1 extracts the gallery search filter / haystack / section-grouping into a pure `nonisolated` `GallerySearch` helper (the issue's "Tests" section expects "gallery cull/search helpers" to be unit-testable), and `GenerationGalleryView` then evaluates the filtered sections exactly once per body pass and shares the value with the `isEmpty` check, the collection view, and the batch-action-bar board menu. Task 2 caches the `fileExists` probe result per normalized path inside `SandboxFileAccess.canReach` behind a 2 s TTL (clock injected for tests); the in-memory grant/`unusable`/`isReadable` logic stays live, and `start()` (the job path) keeps a fresh stat.

**Tech Stack:** Swift 6 (Swift 6 language mode, `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`), SwiftUI, Swift Testing.

**Spec:** https://github.com/MLXBits/image-studio/issues/83 — "Performance" section (two bullets). The current code in `Views/Gallery/GenerationGalleryView.swift` and `Utilities/SandboxFileAccess.swift` is the behavior these tasks must preserve exactly.

## Global Constraints

- Lint gate — both must pass **before** committing (pre-commit also runs the second):
  `swiftformat --lint --config .swiftformat .` and `swiftlint lint --config .swiftlint.yml --baseline .swiftlint-baseline.json --strict`
- Build: `xcodebuild -project "MLXBits Image Studio.xcodeproj" -scheme "MLXBits Image Studio" -configuration Debug build`
- Tests: `xcodebuild -project "MLXBits Image Studio.xcodeproj" -scheme "MLXBits Image Studio" test` — full suite only (never `-only-testing:`); a valid run logs `Test run with N tests in M suites passed`.
- Clean build: zero compiler warnings. Swift 6 isolation mistakes are build errors, not warnings.
- Pure logic off the main actor needs `nonisolated` on the declaration (helpers like `GallerySearch`).
- No UI tests: tests cover pure logic only (Swift Testing `@Test`, `#expect`).
- `type_contents_order` is a custom rule here: type_alias → associated_type → case → subtype → type_property → type_method → instance_property → initializer → view_life_cycle_method → other_method (type_method BEFORE instance_property).
- Cyclomatic complexity ≤ 15; `superfluous_else` trips when every branch early-returns.
- Local commits only — no push, no merge (the parent agent handles PR handoff).
- Do not touch the untracked `IDEA.md` (user scratch) or anything under `build/`, `DerivedData/`.

## Review Focus

1. Behavior identity of the gallery refactor: sections, board order, filter semantics, and per-section item order must be exactly what the view computed before — the diff must be a pure move + single-evaluation hoist, no new branching or state.
2. Search semantics: query matches across prompt, negative prompt, seed, model, and LoRA display names for all four metadata families; `seedVR2Metadata` does NOT enter the haystack (parity with the current code); the query is trimmed and lowercased.
3. `canReach` caching must not mask live grant state: a grant that fails to start flips `canReach` to false even within the TTL (existing `aGrantThatFailsToStartIsNoLongerTrusted` passes unmodified); `remember`/`forget` drop the path's probe.
4. `beginAccess`/`start()` keep a fresh stat — never resolve a bookmark for a path that has vanished (existing `aMissingPathIsNotResolved` passes unmodified).
5. Staleness window: a deleted file may read as reachable for up to 2 s in UI affordances only — acceptable per spec; lease/job paths are never affected.

---

### Task 1: Gallery search — single evaluation per body pass, testable helper

**Files:**
- Create: `Utilities/GallerySearch.swift`
- Modify: `Views/Gallery/GenerationGalleryView.swift` (`modelItems` ~51-75, `orderedBoards` ~94-96, `gallerySections` ~98-118, `body` ~120-141, `batchActionBar` ~504-514 + its Move `Menu` ~619-632, `searchHaystack` ~766-791)
- Test: `Tests/GallerySearchTests.swift` (create)

**Interfaces:**
- Produces: `nonisolated enum GallerySearch` with exactly:
  - `static func haystack(for item: GalleryItem) -> String`
  - `static func filter(_ items: [GalleryItem], family: ModelFamily, query: String, flag: FlagFilter, minRating: Int) -> [GalleryItem]`
  - `static func orderedBoards(for items: [GalleryItem], boards: [String]) -> [String]`
  - `static func sections(_ items: [GalleryItem], boards: [String], collapsed: Set<String>) -> [GallerySection]`
- Consumes: `GalleryItem` (Stores/GalleryStore.swift), `ModelFamily`, `FlagFilter` (Utilities/GalleryRating.swift), `GallerySection` (Views/Gallery/GalleryCollectionView.swift:1085) — all single-target, no import changes.

The logic moves **verbatim** from the view; only `gallery.boards` becomes the `boards:` parameter. Carry the existing explanatory doc comments across.

- [ ] **Step 1: Write the failing tests** in `Tests/GallerySearchTests.swift`.

File-local builders (the metadata types have no defaulted memberwise inits, so build them explicitly; `LoraEntry` has defaults — `LoraEntry(path: "/loras/style.safetensors")` yields `displayName == "style.safetensors"`):

```swift
import Foundation
@testable import MLXBits_Image_Studio
import Testing

final class GallerySearchTests {
    private static let t0 = Date(timeIntervalSince1970: 0)

    private func fluxItem(
        path: String, board: String, metadata: GenerationMetadata? = nil,
        flag: PickFlag? = nil, rating: Int = 0
    ) -> GalleryItem {
        GalleryItem(
            id: UUID(), path: path, board: board, modifiedAt: Self.t0,
            thumbnailData: nil, thumbnailImage: nil, metadata: metadata,
            ideogram4Metadata: nil, krea2Metadata: nil, zimageMetadata: nil,
            seedVR2Metadata: nil, flag: flag, rating: rating
        )
    }

    private func fluxMetadata(
        prompt: String, negativePrompt: String = "", seed: Int = 0,
        loras: [LoraEntry] = []
    ) -> GenerationMetadata {
        GenerationMetadata(
            prompt: prompt, negativePrompt: negativePrompt,
            model: .flux2Klein9B, customModelRepo: "",
            customBaseModel: .flux2KleinBase9B, seed: seed, steps: 20,
            guidance: 3.5, width: 1024, height: 1024, quantize: 8,
            lowRam: false, imagePath: "", imageStrength: 0,
            editImagePaths: nil, loras: loras, board: nil,
            pidDecode: nil, pidDegradeSigma: nil,
            generatedAt: Self.t0, startedAt: nil, log: nil
        )
    }
    // …one builder per family under test (ideogram4 / krea2 / zimage / seedvr2),
    // same shape, real field values, placeholder values elsewhere.
```

Tests (exact expectations — these pin the CURRENT view behavior):

```swift
@Test func theHaystackCoversPromptNegativeSeedModelAndLoras() {
    let item = fluxItem(
        path: "/out/a-portrait.png", board: "Default",
        metadata: fluxMetadata(
            prompt: "A calm PORTRAIT", negativePrompt: "Blurry, extra fingers",
            seed: 42, loras: [LoraEntry(path: "/loras/style.safetensors")]
        )
    )
    #expect(
        GallerySearch.haystack(for: item)
            == "a-portrait.png a calm portrait blurry, extra fingers 42 flux2-klein-9b style.safetensors"
    )
}

@Test func anItemWithoutMetadataHasAFilenameOnlyHaystack() {
    let item = fluxItem(path: "/out/plain.png", board: "Default")
    #expect(GallerySearch.haystack(for: item) == "plain.png")
}

@Test func theHaystackCoversTheIdeogramKrea2AndZImageFamilies() {
    // ideogram: parts = filename, plainPrompt, seed, lora display names
    // krea2:    parts = filename, prompt, seed, lora display names
    // zimage:   parts = filename, prompt, seed, lora display names
    // One #expect per family with the exact joined-lowercased string.
}

@Test func seedVR2MetadataDoesNotEnterTheHaystack() {
    // item whose ONLY metadata is seedVR2Metadata → haystack == filename only
}

@Test func filterKeepsOnlyTheRequestedFamily() {
    // one item per filename prefix (plain → flux, "ideogram4_…", "krea2_…", "zimage_…")
    // filter(family: .krea2) → only the krea2 item
}

@Test func filterHonorsTheFlagFilter() {
    // .all keeps everything; .picks only .pick; .rejects only .reject; .unflagged only nil
}

@Test func filterHonorsTheMinimumRating() {
    // minRating: 3 keeps ratings 3 and 5, drops 2 and 0
}

@Test func theQueryMatchesCaseInsensitivelyAcrossPromptLoraAndSeed() {
    // query "  FoO " (spaces + mixed case) matches an item whose prompt contains "foo"
    // query "42" matches an item whose seed is 42 (and nothing else)
}

@Test func sectionsOrderDefaultFirstThenSortedBoardsAndKeepEncounterOrder() {
    // boards: ["Default", "B", "A"] with items in each (two in B, given in a set
    // order that must be preserved: b2 then b1 as passed)
    // → [Default, A, B]; B's items in the exact order of the input array
}

@Test func aNamedBoardWithNoFilteredItemsStillGetsAnEmptySection() {
    // boards: ["Solo"], one Default item unflagged, filter .picks
    // → sections == [Solo with items == []]; Default gets NO section
}

@Test func collapsedBoardsComeBackUnexpanded() {
    // collapsed: ["A"] → A's section isExpanded == false, B's == true
}

@Test func orderedBoardsListsDefaultOnlyWhenPresent() {
    // items in Default + named → ["Default", "A", "B"] sorted;
    // items only in named → ["A", "B"]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project "MLXBits Image Studio.xcodeproj" -scheme "MLXBits Image Studio" test`
Expected: compile failure — `cannot find 'GallerySearch' in scope`.

- [ ] **Step 3: Implement `Utilities/GallerySearch.swift`**

`nonisolated enum GallerySearch` with the four static functions. Bodies are the view's current logic, verbatim: `haystack` = today's `searchHaystack(for:)` (lines 766-791); `filter` = today's `modelItems` closure (trim + lowercase the query first; family guard, flag switch, rating, then haystack `contains`); `orderedBoards` = today's `orderedBoards(for:)` with `boards` as a parameter (Default first iff present in `items`, then the rest of `boards` minus "Default", sorted); `sections` = today's `gallerySections` grouping (one `Dictionary(grouping: by: \.board)`, map over `orderedBoards`). Keep the explanatory comments about encounter order and the Default-board rule.

- [ ] **Step 4: Run the tests to verify they pass**

Run: same test command. Expected: `Test run with N tests in M suites passed`, zero ` failed after` lines.

- [ ] **Step 5: Refactor `GenerationGalleryView` to use the helper, evaluated once per body pass**

- `modelItems` body → `GallerySearch.filter(gallery.items, family: modelFilter, query: searchText, flag: flagFilter, minRating: minRating)`.
- `orderedBoards` body → `GallerySearch.orderedBoards(for: modelItems, boards: gallery.boards)`.
- `gallerySections` body → `GallerySearch.sections(modelItems, boards: gallery.boards, collapsed: collapsedBoards)`.
- Delete the now-dead private `searchHaystack(for:)`.
- **The perf fix:** at the top of `body` hoist `let sections = gallerySections` and use `sections` in BOTH the `if sections.isEmpty` check and `GalleryCollectionView(sections: sections, …)` (add an explicit `return` around the VStack). Today the computed property is evaluated twice per body pass, rebuilding every haystack twice.
- `batchActionBar` currently reads `orderedBoards` inside its Move menu (a third `modelItems` pass when 2+ items are selected). Give `batchActionBar` a `boards: [String]` parameter, call it as `batchActionBar(boards: sections.map(\.board))`, and use the parameter in the menu's `ForEach`. (`sections.map(\.board)` is exactly `orderedBoards(for: modelItems)`.)
- All other `modelItems` readers (range select, adjacent-item, cull, compare) are user-event handlers, not per-frame — leave them as-is.

- [ ] **Step 6: Lint, build, full suite**

Run (in order): `swiftformat --lint --config .swiftformat .`, `swiftlint lint --config .swiftlint.yml --baseline .swiftlint-baseline.json --strict`, then the build command, then the test command. All green, zero new warnings.

- [ ] **Step 7: Commit**

```bash
git add Utilities/GallerySearch.swift Views/Gallery/GenerationGalleryView.swift Tests/GallerySearchTests.swift
git commit -m "perf: evaluate the gallery's filtered sections once per body pass

Extract the search filter, haystack and section grouping into a pure
GallerySearch helper (unit-tested) and hoist a single `let sections`
in GenerationGalleryView.body, so a body pass — and each frame of a
window resize — filters and haystacks the gallery once instead of
twice (three with a multi-selection active). #83"
```

---

### Task 2: `canReach` — cache the `fileExists` probe behind a 2 s TTL

**Files:**
- Modify: `Utilities/SandboxFileAccess.swift`
- Test: `Tests/FileAccessTests.swift`

**Interfaces:**
- Consumes: existing `SandboxFileAccess.init(storeURL:codec:isReadable:)` — unchanged at the call sites; add a defaulted parameter so all three test helpers (`FileAccessTests.sandbox()`, `SourceImageImportTests`, `AppSettingsFileAccessTests`) keep compiling.
- Produces: `SandboxFileAccess` whose `canReach(_:)` stats a path at most once per 2 s (per normalized path), while grant/`unusable`/`isReadable` stay live. `start()`/`beginAccess`/`beginAccess(toAvailable:)` unchanged.

Design (binding):
- Cache **only the `fileExists` result**, never the whole `canReach` verdict. The grant lookup, the `unusable` check and `isReadable` stay live so a grant that stops resolving flips `canReach` immediately (`aGrantThatFailsToStartIsNoLongerTrusted` depends on this) — and the `open()` syscall in `FileAccessPath.isReadable` stays out of the cache because it only runs for ungranted paths.
- `private struct ExistsProbe { let result: Bool; let at: Date }`; `private var existsProbes: [String: ExistsProbe] = [:]`; `private static let probeTTL: TimeInterval = 2`.
- `init` gains `now: @escaping () -> Date = Date.init` (stored), placed after `isReadable`.
- `private func exists(_ path: String) -> Bool`: return the cached probe while `now().timeIntervalSince(probe.at) < Self.probeTTL`, else `FileManager.default.fileExists(atPath:)`, store and return it. `canReach` calls `exists(normalized)` instead of FileManager.
- `remember(_:)` and `forget(_:)` each drop the probe for the normalized path — re-choosing a file in an open panel (Locate…) or forgetting one must re-probe, not serve up to 2 s of stale verdict.
- No probe-table pruning: distinct local paths the UI asks about are session-bounded (LoRA rows, a handful of path fields), so an unbounded table is fine; say so in the doc comment.
- Doc comment on the TTL: the probes feed UI affordances ("is lost" badges, lock labels) on the main thread — `LoraManagerView` probes one LoRA per row, per body pass. 2 s staleness is imperceptible for badges and bounds main-thread stat work to one per path per 2 s; the job path (`start`) always stats fresh.

- [ ] **Step 1: Write the failing tests** in `Tests/FileAccessTests.swift`.

Extend the private helper to pass a clock through (default keeps every existing call site compiling):

```swift
private func sandbox(
    codec: BookmarkCodec = .securityScoped, isReadable: @escaping (String) -> Bool = FileAccessPath.isReadable,
    now: @escaping () -> Date = Date.init
) -> SandboxFileAccess {
    SandboxFileAccess(storeURL: root.appendingPathComponent("grants.json"), codec: codec, isReadable: isReadable, now: now)
}
```

```swift
/// The canReach probe is cached per path behind a TTL, so a body pass that
/// probes every LoRA row doesn't re-stat the disk on each frame.
@Test func aProbedPathIsNotRestattedWithinTheTTL() throws {
    var now = Date()
    let access = sandbox(now: { now })
    access.remember(lora)
    #expect(access.canReach(lora.path))
    try FileManager.default.removeItem(at: lora)
    #expect(access.canReach(lora.path)) // cached probe, file is gone
    now += 2 // past the 2 s TTL
    #expect(!access.canReach(lora.path))
}

@Test func reChoosingAPathInvalidatesItsProbe() throws {
    var now = Date()
    let access = sandbox(now: { now })
    access.remember(lora)
    #expect(access.canReach(lora.path)) // probe: exists @ t0
    try FileManager.default.removeItem(at: lora)
    now += 2 // TTL lapses
    #expect(!access.canReach(lora.path)) // fresh probe: gone
    try Data("weights".utf8).write(to: lora)
    #expect(!access.canReach(lora.path)) // cached false, still within TTL
    access.remember(lora) // Locate… re-chose the file
    #expect(access.canReach(lora.path)) // remember dropped the stale probe
}

@Test func forgettingAPathDropsItsProbe() throws {
    var now = Date()
    let access = sandbox(now: { now })
    access.remember(lora)
    #expect(access.canReach(lora.path))
    try FileManager.default.removeItem(at: lora)
    access.forget(lora.path)
    #expect(!access.canReach(lora.path)) // probe dropped → fresh stat
}
```

All existing tests in the file stay byte-identical — especially `aGrantThatFailsToStartIsNoLongerTrusted`, `aMissingPathIsNotResolved`, `aDeletedFileIsReportedAsLost`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: the test command. Expected: compile failure — `no exact matches in call` / `extra argument 'now' in call`.

- [ ] **Step 3: Implement the probe cache in `SandboxFileAccess`** per the Design block above.

- [ ] **Step 4: Run the tests to verify they pass**

Run: the test command. Expected: full suite green, including the three new tests and every pre-existing `FileAccessTests` test.

- [ ] **Step 5: Lint, build, full suite** — same order as Task 1 Step 6.

- [ ] **Step 6: Commit**

```bash
git add Utilities/SandboxFileAccess.swift Tests/FileAccessTests.swift
git commit -m "perf: probe canReach file existence at most once per 2 s

The App Store build's canReach ran a fileExists stat (and, for
ungranted paths, an open()) on the main thread for every LoRA row and
path field on every body pass. Cache the fileExists result per
normalized path behind a 2 s TTL (clock injected for tests); keep the
grant/unusable/isReadable logic live and let start() keep statting
fresh. #83"
```

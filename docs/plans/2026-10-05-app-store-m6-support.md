# App Store build, milestone 6: support — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** both builds can ask for support without getting in the way:
- a Support window, opened from the app menu, Settings and a one-time nudge;
- the App Store build sells three consumable tips through StoreKit 2;
- the DMG links to Ko-fi, with a GitHub Sponsors button built but hidden;
- the nudge appears once, after 50 images;
- a person can tip as many times as they like.

**Architecture:**
- **`SupportStore`** (both builds) keeps four app-global facts in `UserDefaults`: images generated, nudge retired, Support window opened, has tipped. A pure rule, `SupportNudge.shouldShow`, decides whether the nudge shows.
- **Counting images:** every `JobRunner` reports the images a finished job saved through `onImagesLanded`, and the app adds them to `SupportStore`. Counting starts with this build; past history isn't counted (the owner's call, 2026-10-05: active users reach 50 either way).
- **Repeat tips:** tips are consumables, so the same tip can be bought again. The buttons stay enabled after a thank-you.
- **`TipJarStore`** (logic, both builds compile it) drives the tip buttons against a `TipStorefront` protocol. `StoreKitStorefront` is the StoreKit 2 implementation; tests use a fake and, separately, `SKTestSession` with `Resources/Tips.storekit`.
- **`SupportLinks`** decides which donation links show. The App Store build shows none.
- **Views:** `SupportView` (a window, like About), `TipJarSection` (App Store), `DonationLinksSection` (DMG), and `SupportNudgeBanner` under the top bar.

**Tech stack:** Swift 5.9 (MainActor default isolation), SwiftUI, StoreKit 2, StoreKitTest, Swift Testing, XcodeGen 2.46.

**Spec:** `docs/specs/2026-10-03-app-store-build-design.md`, §5 (support), §7 (tests and manual checklist item 8, 9) and milestone 6. Read the spec and this plan.

**Branch:** `feature/support`, from `main` (at `bf0e53e` or later).

**Release:** none in this plan. After merge, the owner decides on a DMG release and a TestFlight upload.

### Where this plan departs from the spec, and why

The owner reviews these before execution. Task 7 writes them into the spec.

1. **Support is a small window, like About, not a sheet.** It opens the same way from the app menu, from Settings (a separate window, where a sheet on the main window would appear behind it) and from the nudge.
2. **The cancelled-purchase test uses a fake storefront.** `SKTestSession` can't make `purchase()` return `.userCancelled`. Success, pending and the interrupted purchase run against StoreKitTest; cancelled runs against the fake, as do the load and double-click cases.
3. **Pending and failed purchases show a one-line caption** in the window, not an alert. That is the spec's "handled quietly"; cancelled shows nothing.

## Global Constraints

**Platform:** macOS 26.0, arm64. Bundle IDs: DMG `com.mlxbits.image-studio`, App Store `com.mlxbits.image-studio.appstore`.

**Product IDs (verbatim):**
- `com.mlxbits.image-studio.appstore.tip.small` ($2.99)
- `com.mlxbits.image-studio.appstore.tip.medium` ($4.99)
- `com.mlxbits.image-studio.appstore.tip.large` ($9.99)

Names and prices shown in the app come from StoreKit, never from code.

**Links (DMG only, verbatim):**
- "Support on Ko-fi" → `https://ko-fi.com/mlxbits` (shown)
- "Sponsor on GitHub" → `https://github.com/sponsors/MLXBits` (hidden until GitHub approves the profile)

**The App Store build never shows Ko-fi or GitHub links.**

**Copy (verbatim from the spec):**
- Menu item: `Support MLXBits Image Studio…`, right after About.
- Support window, first line: `Every feature is free. Tips don't unlock anything; they just help keep the project going.`
- Nudge: `Image Studio is free and built in spare time. If it's useful to you, a tip helps cover the costs to build and maintain it. We appreciate anything you can provide.`
- Nudge buttons: `Leave a Tip…` and `No Thanks`. Either one retires the nudge for good.

**Copy (this plan's, for states the spec leaves open):**
- Thanked: `Thank you! Your tip helps keep Image Studio going.`
- Pending: `Your tip is waiting for approval.`
- Failed: `The tip didn't go through. Please try again later.`
- Unavailable: `Tips can't be loaded right now.` with a `Try Again` button.

**Repeat tips:** every tip button works again after a tip, a pending tip or a failure, for as many tips as the person wants.

**Nudge rule:** shows once at least 50 images have been generated across all profiles, unless it was retired, the Support window was opened, or a tip was made. DEBUG builds read a lower threshold from the launch argument `-supportNudgeThreshold <n>`.

**UserDefaults keys (app-global):** `support.imagesGenerated`, `support.nudgeRetired`, `support.windowOpened`, `support.hasTipped`. The unit-test host uses the `MLXBitsImageStudio.TestHost` suite, never `.standard`.

**Every new type compiles in both flavors; `BuildFlavor.isAppStore` only selects** (spec §7).

**Commands:**
- Focused tests: `xcodebuild -workspace /Users/paul/MLXBits.xcworkspace -scheme 'MLXBits Image Studio' -derivedDataPath "$TMPDIR/image-studio-m6-derived" test BUNDLE_PYTHON_RUNTIME=NO '-only-testing:MLXBits Image StudioTests/<Suite>'`
- Full suite: the same without `-only-testing`.
- App Store compile: `xcodebuild -workspace /Users/paul/MLXBits.xcworkspace -scheme 'MLXBits Image Studio (App Store)' -configuration Debug-AppStore -derivedDataPath "$TMPDIR/image-studio-m6-derived" build BUNDLE_PYTHON_RUNTIME=NO CODE_SIGNING_ALLOWED=NO`
- Lint gates (CI's): `swiftformat --lint --config .swiftformat .` and `swiftlint lint --config .swiftlint.yml --baseline .swiftlint-baseline.json --strict`
- After adding or removing files: `xcodegen generate`. Both scheme files are tracked; check `git diff` on them and keep only intended changes.

**Lint traps already hit in this repo:** `type_contents_order` (type properties, then static methods, then instance properties, then initializers), `trailing_closure`, `force_unwrapping` (opt-in, on), `file_length` 500, `function_body_length` 80 outside Views. The build's pre-build SwiftFormat pass rewrites files; re-read a file after building before editing it.

**Tests never touch real data:** `UserDefaults(suiteName: "<Suite>-\(UUID())")` for stores, temp folders for files.

## Review Focus

1. **Tips not set up in App Store Connect yet** (TestFlight before milestone 7), or offline: products come back empty or throw. Expect "Tips can't be loaded right now." with Try Again, never an empty window. Pinned in Task 3 (`emptyOrFailedLoadShowsUnavailable`).
2. **A double click on a tip button** must start one purchase, not two. Pinned in Task 3 (`aSecondPurchaseWhileOneRunsIsIgnored`).
3. **A tip that completes after the window closed, or after a relaunch** (Ask to Buy approved later, interrupted purchase) must still finish the transaction and stop the nudge. Pinned in Task 3 (`aTransactionFinishedLaterCountsAsTipped`) and Task 4 (`anInterruptedTipIsFinishedLater`).
4. **Tipping again:** a second tip, of the same or another size, right after the first must go through and be thanked again. Pinned in Task 3 (`aPersonCanTipAgain`). (Task 4's `theSameTipCanBeBoughtTwice` was dropped in execution: see the ledger.)
5. **A batch where only some images landed** counts the images saved, not the ones requested. Pinned in Task 2 (`imagesLandedCountsWhatTheJobSaved`).

---

### Task 1: Support state and the nudge rule

**Files:**
- Create: `Models/SupportNudge.swift`
- Create: `Stores/SupportStore.swift`
- Test: `Tests/SupportStoreTests.swift`

**Interfaces:**
- Produces:
  - `enum SupportNudge { static let defaultThreshold = 50; static let message: String; static func shouldShow(imagesGenerated: Int, threshold: Int, retired: Bool, tipped: Bool, windowOpened: Bool) -> Bool; static func configuredThreshold(arguments: UserDefaults = .standard) -> Int }`
  - `@Observable final class SupportStore { init(defaults: UserDefaults, threshold: Int = SupportNudge.configuredThreshold()); private(set) var imagesGenerated: Int; var showsNudge: Bool; func recordImages(_ count: Int); func retireNudge(); func noteWindowOpened(); func noteTipped(); var hasTipped: Bool }`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The one-time support nudge (spec §5): after 50 images, unless it was
/// dismissed, the Support window was opened, or a tip was made.
struct SupportStoreTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "SupportStoreTests-\(UUID().uuidString)") ?? .standard
    }

    @Test func theRuleNeedsTheThresholdAndNothingElse() {
        #expect(SupportNudge.shouldShow(imagesGenerated: 50, threshold: 50, retired: false, tipped: false, windowOpened: false))
        #expect(!SupportNudge.shouldShow(imagesGenerated: 49, threshold: 50, retired: false, tipped: false, windowOpened: false))
        #expect(!SupportNudge.shouldShow(imagesGenerated: 80, threshold: 50, retired: true, tipped: false, windowOpened: false))
        #expect(!SupportNudge.shouldShow(imagesGenerated: 80, threshold: 50, retired: false, tipped: true, windowOpened: false))
        #expect(!SupportNudge.shouldShow(imagesGenerated: 80, threshold: 50, retired: false, tipped: false, windowOpened: true))
    }

    @Test func theNudgeAppearsAtTheThresholdAndRetiresForGood() {
        let d = defaults()
        let store = SupportStore(defaults: d, threshold: 3)
        store.recordImages(2)
        #expect(!store.showsNudge)
        store.recordImages(1)
        #expect(store.showsNudge)

        store.retireNudge()
        #expect(!store.showsNudge)
        #expect(!SupportStore(defaults: d, threshold: 3).showsNudge)
    }

    @Test func openingTheWindowOrTippingKeepsItAway() {
        let opened = SupportStore(defaults: defaults(), threshold: 1)
        opened.noteWindowOpened()
        opened.recordImages(5)
        #expect(!opened.showsNudge)

        let tipped = SupportStore(defaults: defaults(), threshold: 1)
        tipped.noteTipped()
        tipped.recordImages(5)
        #expect(!tipped.showsNudge)
        #expect(tipped.hasTipped)
    }

    @Test func theCountSurvivesARelaunch() {
        let d = defaults()
        SupportStore(defaults: d, threshold: 50).recordImages(7)
        #expect(SupportStore(defaults: d, threshold: 50).imagesGenerated == 7)
    }

    @Test func aDebugThresholdComesFromTheLaunchArguments() {
        let d = defaults()
        #expect(SupportNudge.configuredThreshold(arguments: d) == SupportNudge.defaultThreshold)
        d.set(2, forKey: "supportNudgeThreshold")
        #if DEBUG
            #expect(SupportNudge.configuredThreshold(arguments: d) == 2)
        #else
            #expect(SupportNudge.configuredThreshold(arguments: d) == SupportNudge.defaultThreshold)
        #endif
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: focused tests, `<Suite>` = `SupportStoreTests`.
Expected: build FAIL, "cannot find 'SupportNudge' in scope".

- [ ] **Step 3: Write the implementation**

`Models/SupportNudge.swift`:

```swift
import Foundation

/// When the one-time support nudge shows (spec §5).
nonisolated enum SupportNudge {
    static let defaultThreshold = 50
    static let message = "Image Studio is free and built in spare time. If it's useful to you, a tip helps cover the costs "
        + "to build and maintain it. We appreciate anything you can provide."

    /// After `threshold` images, unless it was dismissed, the Support window
    /// was opened, or a tip was made.
    static func shouldShow(imagesGenerated: Int, threshold: Int, retired: Bool, tipped: Bool, windowOpened: Bool) -> Bool {
        imagesGenerated >= threshold && !retired && !tipped && !windowOpened
    }

    /// 50, or in DEBUG builds the launch argument `-supportNudgeThreshold <n>`
    /// (it lands in the arguments domain of `UserDefaults.standard`).
    static func configuredThreshold(arguments: UserDefaults = .standard) -> Int {
        #if DEBUG
            let override = arguments.integer(forKey: "supportNudgeThreshold")
            if override > 0 {
                return override
            }
        #endif
        return defaultThreshold
    }
}
```

`Stores/SupportStore.swift`:

```swift
import Foundation

/// What the support nudge needs to know, app-global rather than per profile
/// (spec §5): images generated, and whether the nudge was dismissed, the
/// Support window opened or a tip made.
@Observable
final class SupportStore {
    private enum Key {
        static let imagesGenerated = "support.imagesGenerated"
        static let nudgeRetired = "support.nudgeRetired"
        static let windowOpened = "support.windowOpened"
        static let hasTipped = "support.hasTipped"
    }

    private(set) var imagesGenerated: Int
    private(set) var nudgeRetired: Bool
    private(set) var windowOpened: Bool
    private(set) var hasTipped: Bool
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let threshold: Int

    init(defaults: UserDefaults, threshold: Int = SupportNudge.configuredThreshold()) {
        self.defaults = defaults
        self.threshold = threshold
        imagesGenerated = defaults.integer(forKey: Key.imagesGenerated)
        nudgeRetired = defaults.bool(forKey: Key.nudgeRetired)
        windowOpened = defaults.bool(forKey: Key.windowOpened)
        hasTipped = defaults.bool(forKey: Key.hasTipped)
    }

    var showsNudge: Bool {
        SupportNudge.shouldShow(
            imagesGenerated: imagesGenerated, threshold: threshold,
            retired: nudgeRetired, tipped: hasTipped, windowOpened: windowOpened
        )
    }

    func recordImages(_ count: Int) {
        guard count > 0 else { return }
        imagesGenerated += count
        defaults.set(imagesGenerated, forKey: Key.imagesGenerated)
    }

    func retireNudge() {
        nudgeRetired = true
        defaults.set(true, forKey: Key.nudgeRetired)
    }

    func noteWindowOpened() {
        windowOpened = true
        defaults.set(true, forKey: Key.windowOpened)
    }

    func noteTipped() {
        hasTipped = true
        defaults.set(true, forKey: Key.hasTipped)
    }
}
```

- [ ] **Step 4: Run them to verify they pass**

Run: `xcodegen generate` (new files), then the focused tests for `SupportStoreTests`.
Expected: 5 tests PASS.

- [ ] **Step 5: Lint and commit**

Run both lint gates. Expected: clean.

```bash
git add Models/SupportNudge.swift Stores/SupportStore.swift Tests/SupportStoreTests.swift "MLXBits Image Studio.xcodeproj"
git commit -m "Support state and the one-time nudge rule"
```

---

### Task 2: New images count toward the nudge

**Files:**
- Modify: `Runner/RunnerSupport.swift` (add `imagesLanded` and `LandedImagesReporting`)
- Modify: `Runner/JobRunner.swift:176-178` (property) and `:744-757` (`finishJob`)
- Modify: `App/MLXBitsImageStudioApp.swift` (`seedVR2Runner` built in `init`; wiring)
- Test: `Tests/RunnerSupportTests.swift`

**Interfaces:**
- Consumes: `SupportStore.recordImages(_:)`.
- Produces: `RunnerSupport.imagesLanded(outputPath: String?, outputPaths: [String]) -> Int`; `protocol LandedImagesReporting: AnyObject { var onImagesLanded: ((Int) -> Void)? { get set } }`; `JobRunner.onImagesLanded`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/RunnerSupportTests.swift`:

```swift
    // MARK: - imagesLanded (support nudge count)

    /// A single image sets only `outputPath`; a batch sets `outputPaths` to
    /// what actually landed.
    @Test func imagesLandedCountsWhatTheJobSaved() {
        #expect(RunnerSupport.imagesLanded(outputPath: "/Lib/a.png", outputPaths: []) == 1)
        #expect(RunnerSupport.imagesLanded(outputPath: "/Lib/a.png", outputPaths: ["/Lib/a.png", "/Lib/b.png"]) == 2)
        #expect(RunnerSupport.imagesLanded(outputPath: nil, outputPaths: []) == 0)
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: focused tests for `RunnerSupportTests`.
Expected: build FAIL, "type 'RunnerSupport' has no member 'imagesLanded'".

- [ ] **Step 3: Write the implementation**

In `Runner/RunnerSupport.swift`, add to `RunnerSupport`:

```swift
    /// Images a completed job saved: each of `outputPaths` for a batch, else
    /// the single `outputPath`.
    static func imagesLanded(outputPath: String?, outputPaths: [String]) -> Int {
        outputPaths.isEmpty ? (outputPath == nil ? 0 : 1) : outputPaths.count
    }
```

and at file scope:

```swift
/// A runner that reports the images each completed job saved (the support
/// nudge's count, spec §5).
protocol LandedImagesReporting: AnyObject {
    var onImagesLanded: ((Int) -> Void)? { get set }
}
```

In `Runner/JobRunner.swift`, after `var driver: MfluxDriverController?`:

```swift
    /// Called with the images each completed job saved.
    var onImagesLanded: ((Int) -> Void)?
```

In `finishJob`, after `job.completedAt = Date()`:

```swift
        if case .completed = status {
            onImagesLanded?(RunnerSupport.imagesLanded(outputPath: job.outputPath, outputPaths: job.outputPaths))
        }
```

At the end of `JobRunner.swift`: `extension JobRunner: LandedImagesReporting {}`.

In `App/MLXBitsImageStudioApp.swift`:
1. `@State private var seedVR2Runner = SeedVR2JobRunner()` becomes `@State private var seedVR2Runner: SeedVR2JobRunner`, and `init` builds it like the others: `let seedVR2Runner = SeedVR2JobRunner()` next to `zimageRunner`, and `_seedVR2Runner = State(initialValue: seedVR2Runner)`. The comment above the runners explains why: a property default mutated in `init` is not the instance SwiftUI installs.
2. Add `@State private var support: SupportStore`.
3. Add this static method above the `@State` properties (`type_contents_order` puts static methods first):

```swift
    /// The support nudge's count: the images every runner saves (spec §5).
    private static func makeSupport(testHost: Bool, runners: [any LandedImagesReporting]) -> SupportStore {
        let support = SupportStore(
            defaults: testHost ? UserDefaults(suiteName: "MLXBitsImageStudio.TestHost") ?? .standard : .standard
        )
        for runner in runners {
            runner.onImagesLanded = { support.recordImages($0) }
        }
        return support
    }
```

4. In `init`, after the runners exist:

```swift
        let support = Self.makeSupport(
            testHost: testHost, runners: [runner, ideogram4Runner, krea2Runner, zimageRunner, seedVR2Runner]
        )
        _support = State(initialValue: support)
```

If `init` passes `function_body_length` 80, move the runner `driver` assignments into the same kind of static helper rather than raising the limit.

- [ ] **Step 4: Run tests and both builds**

Run: focused tests for `RunnerSupportTests`, then the full suite, then the App Store compile.
Expected: all PASS; both builds succeed.

- [ ] **Step 5: Lint and commit**

```bash
git add Runner/RunnerSupport.swift Runner/JobRunner.swift App/MLXBitsImageStudioApp.swift Tests/RunnerSupportTests.swift
git commit -m "Count saved images toward the support nudge"
```

---

### Task 3: Tip jar logic

**Files:**
- Create: `Stores/TipJarStore.swift`
- Create: `Tests/Support/FakeTipStorefront.swift`
- Test: `Tests/TipJarStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct TipProduct: Identifiable, Equatable { let id: String; let displayName: String; let displayPrice: String; let price: Decimal }`
  - `enum TipPurchaseOutcome: Equatable { case tipped, pending, cancelled }`
  - `enum TipJarError: Error { case productUnavailable, unverified }`
  - `protocol TipStorefront: AnyObject { func products(for ids: [String]) async throws -> [TipProduct]; func purchase(_ id: String) async throws -> TipPurchaseOutcome; func finishedTransactions(for ids: Set<String>) -> AsyncStream<Void> }`
  - `@Observable final class TipJarStore { static let productIDs: [String]; enum Phase; private(set) var products: [TipProduct]; private(set) var phase: Phase; var canPurchase: Bool; init(storefront: TipStorefront, onTipped: @escaping () -> Void); func load() async; func purchase(_ id: String) async; func startFinishingTransactions() }`

- [ ] **Step 1: Write the fake and the failing tests**

`Tests/Support/FakeTipStorefront.swift`:

```swift
import Foundation
@testable import MLXBits_Image_Studio

/// A storefront for TipJarStore's tests: set what loading and purchasing
/// return; `gate`, when set, holds a purchase until it opens.
final class FakeTipStorefront: TipStorefront {
    static let tips = [
        TipProduct(id: TipJarStore.productIDs[2], displayName: "Large Tip", displayPrice: "$9.99", price: 9.99),
        TipProduct(id: TipJarStore.productIDs[0], displayName: "Small Tip", displayPrice: "$2.99", price: 2.99),
        TipProduct(id: TipJarStore.productIDs[1], displayName: "Medium Tip", displayPrice: "$4.99", price: 4.99),
    ]

    var catalog: Result<[TipProduct], Error> = .success(tips)
    var outcome: Result<TipPurchaseOutcome, Error> = .success(.tipped)
    var gate: AsyncGate?
    private(set) var purchases: [String] = []
    let finished = AsyncStream<Void>.makeStream()

    func products(for _: [String]) async throws -> [TipProduct] {
        try catalog.get()
    }

    func purchase(_ id: String) async throws -> TipPurchaseOutcome {
        purchases.append(id)
        await gate?.wait()
        return try outcome.get()
    }

    func finishedTransactions(for _: Set<String>) -> AsyncStream<Void> {
        finished.stream
    }
}
```

`Tests/TipJarStoreTests.swift`:

```swift
import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The App Store tip jar (spec §5): three consumable tips that unlock nothing.
struct TipJarStoreTests {
    private struct Failure: Error {}

    private func store(_ fake: FakeTipStorefront, tipped: @escaping () -> Void = {}) -> TipJarStore {
        TipJarStore(storefront: fake, onTipped: tipped)
    }

    @Test func tipsLoadCheapestFirst() async {
        let jar = store(FakeTipStorefront())
        await jar.load()
        #expect(jar.phase == .ready)
        #expect(jar.products.map(\.displayPrice) == ["$2.99", "$4.99", "$9.99"])
    }

    @Test func emptyOrFailedLoadShowsUnavailable() async {
        let empty = FakeTipStorefront()
        empty.catalog = .success([])
        let emptyJar = store(empty)
        await emptyJar.load()
        #expect(emptyJar.phase == .unavailable)

        let failing = FakeTipStorefront()
        failing.catalog = .failure(Failure())
        let failingJar = store(failing)
        await failingJar.load()
        #expect(failingJar.phase == .unavailable)

        failing.catalog = .success(FakeTipStorefront.tips)
        await failingJar.load()
        #expect(failingJar.phase == .ready)
    }

    @Test func aTipThanksAndRecordsIt() async {
        var tipped = 0
        let fake = FakeTipStorefront()
        let jar = store(fake) { tipped += 1 }
        await jar.load()
        await jar.purchase(TipJarStore.productIDs[0])
        #expect(jar.phase == .thanked)
        #expect(tipped == 1)
        #expect(jar.canPurchase)
    }

    /// Tips are consumables: the same tip, or another, can be left again
    /// right after a thank-you.
    @Test func aPersonCanTipAgain() async {
        var tipped = 0
        let fake = FakeTipStorefront()
        let jar = store(fake) { tipped += 1 }
        await jar.load()
        await jar.purchase(TipJarStore.productIDs[0])
        await jar.purchase(TipJarStore.productIDs[0])
        await jar.purchase(TipJarStore.productIDs[2])
        #expect(fake.purchases == [TipJarStore.productIDs[0], TipJarStore.productIDs[0], TipJarStore.productIDs[2]])
        #expect(tipped == 3)
        #expect(jar.phase == .thanked)
    }

    @Test func cancelledAndPendingAreQuiet() async {
        var tipped = 0
        let fake = FakeTipStorefront()
        let jar = store(fake) { tipped += 1 }
        await jar.load()

        fake.outcome = .success(.cancelled)
        await jar.purchase(TipJarStore.productIDs[0])
        #expect(jar.phase == .ready)

        fake.outcome = .success(.pending)
        await jar.purchase(TipJarStore.productIDs[0])
        #expect(jar.phase == .pending)
        #expect(tipped == 0)
    }

    @Test func aFailedPurchaseSaysSo() async {
        let fake = FakeTipStorefront()
        fake.outcome = .failure(TipJarError.unverified)
        let jar = store(fake)
        await jar.load()
        await jar.purchase(TipJarStore.productIDs[0])
        #expect(jar.phase == .failed)
        #expect(jar.canPurchase)
    }

    @Test func aSecondPurchaseWhileOneRunsIsIgnored() async {
        let fake = FakeTipStorefront()
        let gate = AsyncGate()
        fake.gate = gate
        let jar = store(fake)
        await jar.load()

        let first = Task { await jar.purchase(TipJarStore.productIDs[0]) }
        while fake.purchases.isEmpty {
            await Task.yield()
        }
        #expect(!jar.canPurchase)
        await jar.purchase(TipJarStore.productIDs[1])
        gate.open()
        await first.value
        #expect(fake.purchases == [TipJarStore.productIDs[0]])
    }

    /// Ask to Buy approved later, or a purchase interrupted last launch.
    @Test func aTransactionFinishedLaterCountsAsTipped() async {
        var tipped = 0
        let fake = FakeTipStorefront()
        let jar = store(fake) { tipped += 1 }
        jar.startFinishingTransactions()
        jar.startFinishingTransactions()
        fake.finished.continuation.yield()
        for _ in 0 ..< 100 where tipped == 0 {
            await Task.yield()
        }
        #expect(tipped == 1)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodegen generate`, then focused tests for `TipJarStoreTests`.
Expected: build FAIL, "cannot find type 'TipStorefront' in scope".

- [ ] **Step 3: Write the implementation**

`Stores/TipJarStore.swift`:

```swift
import Foundation

/// One tip as the store sells it: name and local price come from the store,
/// never from code (spec §5).
struct TipProduct: Identifiable, Equatable {
    let id: String
    let displayName: String
    let displayPrice: String
    let price: Decimal
}

/// How a tip purchase ended. Failures throw.
enum TipPurchaseOutcome: Equatable {
    case tipped
    case pending
    case cancelled
}

enum TipJarError: Error {
    case productUnavailable
    case unverified
}

/// Where tips are bought: StoreKit in the app (``StoreKitStorefront``), a fake
/// in tests.
protocol TipStorefront: AnyObject {
    func products(for ids: [String]) async throws -> [TipProduct]
    /// Buys, verifies and finishes one tip.
    func purchase(_ id: String) async throws -> TipPurchaseOutcome
    /// Finishes tips that completed outside a purchase call (Ask to Buy
    /// approved later, a purchase interrupted last launch), yielding once for
    /// each.
    func finishedTransactions(for ids: Set<String>) -> AsyncStream<Void>
}

/// The App Store build's tip jar: three consumable tips that unlock nothing.
@Observable
final class TipJarStore {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case unavailable
        case purchasing(String)
        case thanked
        case pending
        case failed
    }

    static let productIDs = [
        "com.mlxbits.image-studio.appstore.tip.small",
        "com.mlxbits.image-studio.appstore.tip.medium",
        "com.mlxbits.image-studio.appstore.tip.large",
    ]

    private(set) var products: [TipProduct] = []
    private(set) var phase: Phase = .idle
    @ObservationIgnored private let storefront: TipStorefront
    @ObservationIgnored private let onTipped: () -> Void
    @ObservationIgnored private var finishing: Task<Void, Never>?

    init(storefront: TipStorefront, onTipped: @escaping () -> Void) {
        self.storefront = storefront
        self.onTipped = onTipped
    }

    /// Tip buttons work once tips have loaded and no purchase is running.
    var canPurchase: Bool {
        switch phase {
        case .ready, .thanked, .pending, .failed: true
        case .idle, .loading, .unavailable, .purchasing: false
        }
    }

    /// Loads the tips, cheapest first. Again after a failure (Try Again).
    func load() async {
        guard phase == .idle || phase == .unavailable else { return }
        phase = .loading
        do {
            products = try await storefront.products(for: Self.productIDs).sorted { $0.price < $1.price }
            phase = products.isEmpty ? .unavailable : .ready
        } catch {
            phase = .unavailable
        }
    }

    func purchase(_ id: String) async {
        guard canPurchase, products.contains(where: { $0.id == id }) else { return }
        phase = .purchasing(id)
        do {
            switch try await storefront.purchase(id) {
            case .tipped:
                phase = .thanked
                onTipped()
            case .pending:
                phase = .pending
            case .cancelled:
                phase = .ready
            }
        } catch {
            phase = .failed
        }
    }

    /// Started once at launch: finishes tips that complete outside a purchase.
    func startFinishingTransactions() {
        guard finishing == nil else { return }
        let finished = storefront.finishedTransactions(for: Set(Self.productIDs))
        finishing = Task { [onTipped] in
            for await _ in finished {
                onTipped()
            }
        }
    }
}
```

- [ ] **Step 4: Run them to verify they pass**

Run: focused tests for `TipJarStoreTests`.
Expected: 8 tests PASS.

- [ ] **Step 5: Lint and commit**

```bash
git add Stores/TipJarStore.swift Tests/Support/FakeTipStorefront.swift Tests/TipJarStoreTests.swift "MLXBits Image Studio.xcodeproj"
git commit -m "Tip jar logic behind a storefront protocol"
```

---

### Task 4: StoreKit storefront and the local StoreKit configuration

**Files:**
- Create: `Utilities/StoreKitStorefront.swift`
- Create: `Resources/Tips.storekit`
- Modify: `project.yml` (test target resource; App Store scheme's StoreKit configuration)
- Test: `Tests/StoreKitStorefrontTests.swift`

**Interfaces:**
- Consumes: `TipStorefront`, `TipProduct`, `TipPurchaseOutcome`, `TipJarError`, `TipJarStore.productIDs`.
- Produces: `final class StoreKitStorefront: TipStorefront` with `init()`.

- [ ] **Step 1: Write the StoreKit configuration**

`Resources/Tips.storekit` (Xcode's StoreKit configuration format, version 4):

```json
{
  "identifier" : "4C7E9B21",
  "nonRenewingSubscriptions" : [],
  "products" : [
    {
      "displayPrice" : "2.99",
      "familyShareable" : false,
      "internalID" : "6740000001",
      "localizations" : [
        { "description" : "A small tip. It unlocks nothing; it helps keep Image Studio going.", "displayName" : "Small Tip", "locale" : "en_US" }
      ],
      "productID" : "com.mlxbits.image-studio.appstore.tip.small",
      "referenceName" : "Small Tip",
      "type" : "Consumable"
    },
    {
      "displayPrice" : "4.99",
      "familyShareable" : false,
      "internalID" : "6740000002",
      "localizations" : [
        { "description" : "A medium tip. It unlocks nothing; it helps keep Image Studio going.", "displayName" : "Medium Tip", "locale" : "en_US" }
      ],
      "productID" : "com.mlxbits.image-studio.appstore.tip.medium",
      "referenceName" : "Medium Tip",
      "type" : "Consumable"
    },
    {
      "displayPrice" : "9.99",
      "familyShareable" : false,
      "internalID" : "6740000003",
      "localizations" : [
        { "description" : "A large tip. It unlocks nothing; it helps keep Image Studio going.", "displayName" : "Large Tip", "locale" : "en_US" }
      ],
      "productID" : "com.mlxbits.image-studio.appstore.tip.large",
      "referenceName" : "Large Tip",
      "type" : "Consumable"
    }
  ],
  "settings" : {
    "_failTransactionsEnabled" : false,
    "_locale" : "en_US",
    "_storefront" : "USA",
    "_storeKitErrors" : []
  },
  "subscriptionGroups" : [],
  "version" : { "major" : 4, "minor" : 0 }
}
```

- [ ] **Step 2: Wire it into the project**

In `project.yml`:
- The test target's `sources` becomes:

```yaml
    sources:
      - Tests
      - path: Resources/Tips.storekit
        buildPhase: resources
```

- The App Store scheme's `run` gains the configuration (local purchases in Xcode, never shipped):

```yaml
    run:
      config: Debug-AppStore
      storeKitConfiguration: Resources/Tips.storekit
```

The app target lists its resources one by one, so `Tips.storekit` is not copied into the app.

Run: `xcodegen generate`, then `git diff --stat`.
Expected: `project.pbxproj` and the App Store `.xcscheme` change (the scheme gains a `StoreKitConfigurationFileReference`); the DMG scheme doesn't. If the DMG scheme changes in ways unrelated to this task, restore it with `git checkout` on that file.

- [ ] **Step 3: Write the failing tests**

`Tests/StoreKitStorefrontTests.swift`:

```swift
import Foundation
@testable import MLXBits_Image_Studio
import StoreKit
import StoreKitTest
import Testing

/// StoreKit 2 against `Resources/Tips.storekit` (spec §7). Serialized: the
/// test session is process-wide.
@Suite(.serialized)
struct StoreKitStorefrontTests {
    private final class BundleToken {}

    private func session() throws -> SKTestSession {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "Tips", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        return session
    }

    private func unfinishedCount() async -> Int {
        var count = 0
        for await _ in Transaction.unfinished {
            count += 1
        }
        return count
    }

    @Test func theThreeTipsLoad() async throws {
        _ = try session()
        let products = try await StoreKitStorefront().products(for: TipJarStore.productIDs)
        #expect(Set(products.map(\.id)) == Set(TipJarStore.productIDs))
        #expect(products.map { ($0.price as NSDecimalNumber).doubleValue }.sorted() == [2.99, 4.99, 9.99])
    }

    @Test func aTipIsVerifiedAndFinished() async throws {
        _ = try session()
        let storefront = StoreKitStorefront()
        _ = try await storefront.products(for: TipJarStore.productIDs)
        #expect(try await storefront.purchase(TipJarStore.productIDs[0]) == .tipped)
        #expect(await unfinishedCount() == 0)
    }

    @Test func theSameTipCanBeBoughtTwice() async throws {
        _ = try session()
        let storefront = StoreKitStorefront()
        _ = try await storefront.products(for: TipJarStore.productIDs)
        #expect(try await storefront.purchase(TipJarStore.productIDs[1]) == .tipped)
        #expect(try await storefront.purchase(TipJarStore.productIDs[1]) == .tipped)
        #expect(await unfinishedCount() == 0)
    }

    @Test func askToBuyIsPending() async throws {
        let session = try session()
        session.askToBuyEnabled = true
        let storefront = StoreKitStorefront()
        _ = try await storefront.products(for: TipJarStore.productIDs)
        #expect(try await storefront.purchase(TipJarStore.productIDs[1]) == .pending)
    }

    @Test func anUnloadedTipCantBeBought() async throws {
        _ = try session()
        await #expect(throws: TipJarError.self) { try await StoreKitStorefront().purchase(TipJarStore.productIDs[0]) }
    }

    /// A tip bought outside a purchase call, as an interrupted purchase is
    /// at the next launch, is finished by the listener.
    @Test func anInterruptedTipIsFinishedLater() async throws {
        let session = try session()
        _ = try await session.buyProduct(identifier: TipJarStore.productIDs[2])
        #expect(await unfinishedCount() == 1)

        let storefront = StoreKitStorefront()
        var finished = storefront.finishedTransactions(for: Set(TipJarStore.productIDs)).makeAsyncIterator()
        _ = await finished.next()
        #expect(await unfinishedCount() == 0)
    }
}
```

- [ ] **Step 4: Run them to verify they fail**

Run: `xcodegen generate`, then focused tests for `StoreKitStorefrontTests`.
Expected: build FAIL, "cannot find 'StoreKitStorefront' in scope".

- [ ] **Step 5: Write the implementation**

`Utilities/StoreKitStorefront.swift`:

```swift
import Foundation
import StoreKit

/// StoreKit 2 behind ``TipStorefront``. Only the App Store build calls it;
/// it compiles in both (spec §7).
final class StoreKitStorefront: TipStorefront {
    private var loaded: [String: Product] = [:]

    private static func verified(_ result: VerificationResult<Transaction>) throws -> Transaction {
        switch result {
        case let .verified(transaction): transaction
        case .unverified: throw TipJarError.unverified
        }
    }

    func products(for ids: [String]) async throws -> [TipProduct] {
        let products = try await Product.products(for: ids)
        loaded = Dictionary(products.map { ($0.id, $0) }) { first, _ in first }
        return products.map { TipProduct(id: $0.id, displayName: $0.displayName, displayPrice: $0.displayPrice, price: $0.price) }
    }

    func purchase(_ id: String) async throws -> TipPurchaseOutcome {
        guard let product = loaded[id] else { throw TipJarError.productUnavailable }
        switch try await product.purchase() {
        case let .success(verification):
            let transaction = try Self.verified(verification)
            await transaction.finish()
            return .tipped
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    /// Unfinished tips from before (an interrupted purchase), then every later
    /// update (Ask to Buy approved). Unverified ones are left alone.
    func finishedTransactions(for ids: Set<String>) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.unfinished {
                    await Self.finish(result, ids: ids, continuation: continuation)
                }
                for await result in Transaction.updates {
                    await Self.finish(result, ids: ids, continuation: continuation)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func finish(
        _ result: VerificationResult<Transaction>, ids: Set<String>, continuation: AsyncStream<Void>.Continuation
    ) async {
        guard let transaction = try? verified(result), ids.contains(transaction.productID) else { return }
        await transaction.finish()
        continuation.yield()
    }
}
```

`type_contents_order` puts static methods before instance properties. If lint flags `verified` or `finish`, move both above `loaded`.

- [ ] **Step 6: Run them to verify they pass**

Run: focused tests for `StoreKitStorefrontTests`.
Expected: 6 tests PASS.

If they pass locally but hang or fail on CI only because StoreKitTest isn't available there, gate the suite with `.enabled(if: ProcessInfo.processInfo.environment["STOREKIT_TESTS"] != "0")`, set `TEST_RUNNER_STOREKIT_TESTS: "0"` on CI's test step, and ledger the ruling. Don't do this pre-emptively.

- [ ] **Step 7: Lint and commit**

```bash
git add Utilities/StoreKitStorefront.swift Resources/Tips.storekit project.yml Tests/StoreKitStorefrontTests.swift "MLXBits Image Studio.xcodeproj"
git commit -m "StoreKit 2 storefront and the local tip configuration"
```

---

### Task 5: The Support window, its menu item, and the Settings section

**Files:**
- Create: `Utilities/SupportLinks.swift`
- Create: `Views/Support/SupportView.swift`
- Create: `Views/Support/TipJarSection.swift`
- Create: `Views/Support/DonationLinksSection.swift`
- Modify: `App/MLXBitsImageStudioApp.swift` (window scene, environments, tip jar at launch, menu item)
- Modify: `Views/Settings/SettingsView.swift` (Support section in the Advanced tab)
- Test: `Tests/SupportLinksTests.swift`

**Interfaces:**
- Consumes: `SupportStore`, `TipJarStore`, `StoreKitStorefront`, `BuildFlavor.isAppStore`.
- Produces: `SupportView.windowID = "support"`; `SupportLinks.visible(isAppStore:gitHubSponsorsApproved:) -> [SupportLinks.Link]`.

- [ ] **Step 1: Write the failing test**

`Tests/SupportLinksTests.swift`:

```swift
@testable import MLXBits_Image_Studio
import Testing

/// Donation links (spec §5): Ko-fi in the DMG, GitHub only once approved, and
/// none at all in the App Store build.
struct SupportLinksTests {
    @Test func theAppStoreBuildShowsNoLinks() {
        #expect(SupportLinks.visible(isAppStore: true, gitHubSponsorsApproved: true).isEmpty)
        #expect(SupportLinks.visible(isAppStore: true, gitHubSponsorsApproved: false).isEmpty)
    }

    @Test func theDMGShowsKoFiAndGitHubOnceApproved() {
        #expect(SupportLinks.visible(isAppStore: false, gitHubSponsorsApproved: false).map(\.url.absoluteString)
            == ["https://ko-fi.com/mlxbits"])
        #expect(SupportLinks.visible(isAppStore: false, gitHubSponsorsApproved: true).map(\.url.absoluteString)
            == ["https://ko-fi.com/mlxbits", "https://github.com/sponsors/MLXBits"])
    }

    @Test func gitHubSponsorsStaysHiddenUntilApproved() {
        #expect(!SupportLinks.gitHubSponsorsApproved)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodegen generate`, then focused tests for `SupportLinksTests`.
Expected: build FAIL, "cannot find 'SupportLinks' in scope".

- [ ] **Step 3: Write `SupportLinks`**

`Utilities/SupportLinks.swift`:

```swift
import Foundation

/// The DMG's donation links (spec §5). The App Store build shows none: outside
/// the US storefront, links to other payment methods break Apple's rules.
nonisolated enum SupportLinks {
    struct Link: Identifiable, Equatable {
        let title: String
        let url: URL

        var id: String {
            url.absoluteString
        }
    }

    /// Flip once GitHub approves the MLXBits Sponsors profile.
    static let gitHubSponsorsApproved = false

    // swiftlint:disable force_unwrapping
    static let koFi = Link(title: "Support on Ko-fi", url: URL(string: "https://ko-fi.com/mlxbits")!)
    static let gitHubSponsors = Link(title: "Sponsor on GitHub", url: URL(string: "https://github.com/sponsors/MLXBits")!)
    // swiftlint:enable force_unwrapping

    static func visible(isAppStore: Bool, gitHubSponsorsApproved: Bool) -> [Link] {
        guard !isAppStore else { return [] }
        return gitHubSponsorsApproved ? [koFi, gitHubSponsors] : [koFi]
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: focused tests for `SupportLinksTests`.
Expected: 3 tests PASS.

- [ ] **Step 5: Write the views**

`Views/Support/SupportView.swift`:

```swift
import SwiftUI

/// The Support window (spec §5), opened from the app menu, Settings and the
/// nudge. Opening it retires the nudge.
struct SupportView: View {
    static let windowID = "support"
    static let intro = "Every feature is free. Tips don't unlock anything; they just help keep the project going."

    @Environment(SupportStore.self) private var support

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.pink)
            Text("Support MLXBits Image Studio")
                .font(.title3.bold())
            Text(Self.intro)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if BuildFlavor.isAppStore {
                TipJarSection()
            } else {
                DonationLinksSection()
            }
        }
        .padding(28)
        .frame(width: 400)
        .onAppear { support.noteWindowOpened() }
    }
}
```

`Views/Support/TipJarSection.swift`:

```swift
import SwiftUI

/// The App Store build's three tips, with names and prices from the store.
struct TipJarSection: View {
    @Environment(TipJarStore.self) private var tipJar

    /// The caption under the tips for a finished, waiting or failed purchase.
    static func note(for phase: TipJarStore.Phase) -> String? {
        switch phase {
        case .thanked: "Thank you! Your tip helps keep Image Studio going."
        case .pending: "Your tip is waiting for approval."
        case .failed: "The tip didn't go through. Please try again later."
        default: nil
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            switch tipJar.phase {
            case .idle, .loading:
                ProgressView().controlSize(.small)
            case .unavailable:
                Text("Tips can't be loaded right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Try Again") { Task { await tipJar.load() } }
                    .buttonStyle(.bordered)
            default:
                HStack(spacing: 10) {
                    ForEach(tipJar.products) { product in
                        Button {
                            Task { await tipJar.purchase(product.id) }
                        } label: {
                            VStack(spacing: 2) {
                                Text(product.displayName)
                                Text(product.displayPrice)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minWidth: 88)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(!tipJar.canPurchase)
                    }
                }
                if let note = Self.note(for: tipJar.phase) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await tipJar.load() }
    }
}
```

`Views/Support/DonationLinksSection.swift`:

```swift
import SwiftUI

/// The DMG's donation links: Ko-fi, and GitHub Sponsors once approved.
struct DonationLinksSection: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 10) {
            ForEach(SupportLinks.visible(isAppStore: BuildFlavor.isAppStore, gitHubSponsorsApproved: SupportLinks.gitHubSponsorsApproved)) { link in
                Button(link.title) { openURL(link.url) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }
}
```

- [ ] **Step 6: Wire the window, the tip jar and the menu item**

In `App/MLXBitsImageStudioApp.swift`:
1. Add `@State private var tipJar: TipJarStore`.
2. In `init`, after `support` exists:

```swift
        let tipJar = TipJarStore(storefront: StoreKitStorefront()) { support.noteTipped() }
        // Tips interrupted last launch, or approved later, are finished as
        // soon as the app starts (spec §5).
        if BuildFlavor.isAppStore, !testHost {
            tipJar.startFinishingTransactions()
        }
        _tipJar = State(initialValue: tipJar)
```

If this pushes `init` over `function_body_length`, fold these lines into `makeSupport`, returning `(SupportStore, TipJarStore)`.

3. Add `.environment(support)` to the main `WindowGroup` content and to `Settings { SettingsView() … }`.
4. Add the window scene after the About window:

```swift
        Window("Support MLXBits Image Studio", id: SupportView.windowID) {
            SupportView()
                .environment(support)
                .environment(tipJar)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
```

5. In `AboutCommands`, after the About button, inside the same `CommandGroup(replacing: .appInfo)`:

```swift
            Button("Support MLXBits Image Studio…") {
                openWindow(id: SupportView.windowID)
            }
```

- [ ] **Step 7: Add the Settings section**

In `Views/Settings/SettingsView.swift`, add `@Environment(\.openWindow) private var openWindow` with the other environment properties, and append this section as the last one in the Advanced tab's `Form`:

```swift
            Section("Support") {
                LabeledContent("Every feature is free.") {
                    Button("Support MLXBits Image Studio…") { openWindow(id: SupportView.windowID) }
                }
            }
```

- [ ] **Step 8: Build both flavors and run the full suite**

Run: `xcodegen generate`, the full suite, then the App Store compile.
Expected: all PASS; both builds succeed.

- [ ] **Step 9: Lint and commit**

```bash
git add Utilities/SupportLinks.swift Views/Support App/MLXBitsImageStudioApp.swift Views/Settings/SettingsView.swift Tests/SupportLinksTests.swift "MLXBits Image Studio.xcodeproj"
git commit -m "Support window: tips in the App Store build, Ko-fi in the DMG"
```

---

### Task 6: The nudge banner

**Files:**
- Create: `Views/Support/SupportNudgeBanner.swift`
- Modify: `App/ContentView.swift` (top `safeAreaInset`, after `MissingLibraryBanner()`; environment declaration)

**Interfaces:**
- Consumes: `SupportStore.showsNudge`, `SupportStore.retireNudge()`, `SupportNudge.message`, `SupportView.windowID`.

There's no new pure logic here (Task 1 tests the rule). The check is the build and the manual run in Task 7.

- [ ] **Step 1: Write the banner**

`Views/Support/SupportNudgeBanner.swift`:

```swift
import SwiftUI

/// The one-time support nudge under the top bar (spec §5). Either button
/// retires it for good.
struct SupportNudgeBanner: View {
    @Environment(SupportStore.self) private var support
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if support.showsNudge {
            HStack(spacing: 8) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink)
                    .font(.caption)
                Text(SupportNudge.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("No Thanks") { support.retireNudge() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                Button("Leave a Tip…") {
                    support.retireNudge()
                    openWindow(id: SupportView.windowID)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
```

- [ ] **Step 2: Put it under the top bar**

In `App/ContentView.swift`, in the top `safeAreaInset`'s `VStack` (next to `ToolchainBanner()` and `MissingLibraryBanner()`), add `SupportNudgeBanner()` after `MissingLibraryBanner()`.

- [ ] **Step 3: Build both flavors, run the full suite, lint**

Run: `xcodegen generate`, the full suite, the App Store compile, both lint gates.
Expected: all PASS, clean.

- [ ] **Step 4: Commit**

```bash
git add Views/Support/SupportNudgeBanner.swift App/ContentView.swift "MLXBits Image Studio.xcodeproj"
git commit -m "One-time support nudge under the top bar"
```

---

### Task 7: Docs, hand-off checks

**Files:**
- Modify: `docs/specs/2026-10-03-app-store-build-design.md` (§5, §7)
- Modify: `AGENTS.md`, `README.md` (only where they describe Settings, the app menu or flavors)

- [ ] **Step 1: Write the departures into the spec**

In §5, after "**Shared Support sheet.**":
- Replace "sheet" with "window" in the heading and the three bullets' lead-in, and add one line: "A window like About, not a sheet: Settings is a separate window, and a sheet on the main window would open behind it (decided in milestone 6)."
- Under "**The nudge.**", add: "Counting starts with the build that adds it; past queue history isn't counted (decided in milestone 6)."
- Under the StoreKit bullets, add: "**Repeat tips:** consumables, so a person can tip again, the same size or another; the buttons stay enabled after a thank-you."
- Under the StoreKit bullets, add: "**Quiet outcomes:** cancelled shows nothing; pending and failed show a one-line caption in the window."

In §7's "Tip jar" bullet, add: "Cancelled runs against a fake storefront: `SKTestSession` can't produce `.userCancelled`."

- [ ] **Step 2: Update AGENTS.md and README.md**

Search both for "Settings", "About" and "App Store". Where they list the app menu, Settings sections or flavor differences, add the Support window, the nudge, and the App Store / DMG split (tips vs. Ko-fi). Mention the debug threshold launch argument in AGENTS.md: `-supportNudgeThreshold <n>` (DEBUG builds).

- [ ] **Step 3: Full verification**

Run: full suite, App Store compile, both lint gates.
Expected: all pass, clean.

- [ ] **Step 4: Commit**

```bash
git add docs/specs/2026-10-03-app-store-build-design.md AGENTS.md README.md
git commit -m "docs: support window, nudge counting and tip outcomes"
```

- [ ] **Step 5: Owner's manual checks** (in the hand-off, not run by the executor)

1. **DMG, Debug** with `-supportNudgeThreshold 2` in the scheme's arguments:
   - Make two images: the nudge appears. Check the wording and the two buttons.
   - No Thanks: the nudge is gone and stays gone after a relaunch.
   - The app menu has "Support MLXBits Image Studio…" right after About. The window shows the intro line and **Support on Ko-fi** (opens the page). No GitHub button.
   - Settings ▸ Advanced ▸ Support opens the same window.
2. **App Store scheme, Debug-AppStore**, run from Xcode (it uses `Tips.storekit`), with `-supportNudgeThreshold 2`. Make two images:
   - The nudge appears after the second. Leave a Tip… opens the window and retires the nudge.
   - Three tips, cheapest first, with prices. Buy one: the thank-you line shows. Buy the same one again, then another: each goes through. No Ko-fi or GitHub link anywhere.
   - Xcode ▸ Debug ▸ StoreKit ▸ Manage Transactions: the purchase is listed and finished.
   - Enable Ask to Buy in the StoreKit configuration's editor, buy again: "waiting for approval". Approve it in Manage Transactions: no error, the app finishes it.
3. **TestFlight sandbox purchase:** needs the three in-app purchases created in App Store Connect (spec §6 step 5, milestone 7). Until then, the TestFlight build shows "Tips can't be loaded right now." That is expected, not a bug.

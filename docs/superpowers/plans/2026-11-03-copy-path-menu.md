# Copy Path Context Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Copy Path" context-menu submenu (Relative / Absolute) directly above "Reveal in Finder" in every center-pane preview and the single-selected gallery thumbnail, copying the image file's path to the pasteboard.

**Architecture:** A small pure, testable helper (`PathCopy`) computes an image path relative to the app's output directory (falling back to the absolute path when the file isn't under it) and writes a string to the pasteboard. Each SwiftUI preview adds a `Menu("Copy Path")` above its "Reveal in Finder" button; the AppKit gallery thumbnail menu adds an `NSMenuItem` submenu gated on single-selection.

**Tech Stack:** Swift 5.9, SwiftUI + AppKit, Swift Testing, macOS 26.

**Spec:** docs/superpowers/specs/2026-11-03-copy-path-menu-design.md

## Global Constraints
- Swift 5.9 with `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` — types are main-actor isolated by default; no explicit isolation annotations needed.
- Tests are Swift Testing (`@Test`, `#expect`), pure logic only — no UI tests.
- Lint gate must pass before reporting done: `swiftformat --lint --config .swiftformat .` and `swiftlint lint --config .swiftlint.yml --baseline .swiftlint-baseline.json --strict` (SwiftFormat 0.64.1, SwiftLint 0.65.1).
- "Copy Path" copies the **image** file path (`item.path` / `job.outputPath`), never the sidecar `.json`.
- "Relative" = relative to `AppSettings.outputDir`; "Absolute" = the full path.
- The submenu sits directly **above** the existing "Reveal in Finder" item.
- In the gallery, "Copy Path" shows only when exactly one item is selected (`multiSelectionIds.count == 1`); hidden for multi-selection.

## Review Focus
- Image not under the output dir (e.g. an adopted source image): "Relative" must copy the absolute path, not a broken relative path. → Task 1 test `relativeFallsBackToAbsoluteWhenNotUnderBase`.
- Output dir with a trailing slash: "Relative" must still strip it correctly. → Task 1 test `relativeHandlesTrailingSlashBase`.
- Sibling dir whose name starts with the output-dir string (`/out` vs `/outside`): must not be treated as under the output dir. → Task 1 test `relativeDoesNotMatchSiblingDirPrefix`.
- Gallery multi-selection (2+ items): "Copy Path" must be absent from the thumbnail menu. → Task 3 (manual — no UI tests).
- Gallery single-selection: "Copy Path" present and copies the right-clicked item's path. → Task 3 (manual).

---

### Task 1: PathCopy helper + unit test

**Files:**
- Create: `Utilities/PathCopy.swift`
- Test: `Tests/PathCopyTests.swift`

**Interfaces:**
- Produces: `enum PathCopy` with:
  - `static func relative(_ path: String, to base: String) -> String` — returns `path` relative to `base` when `path` is under `base`; otherwise returns `path` unchanged.
  - `static func copy(_ string: String)` — writes `string` to the general pasteboard, replacing prior contents.

- [ ] **Step 1: Write the failing test**

Create `Tests/PathCopyTests.swift`:

```swift
@testable import MLXBits_Image_Studio
import Testing

@Suite("PathCopy")
struct PathCopyTests {
    @Test func relativeStripsOutputDirPrefix() {
        #expect(PathCopy.relative("/Users/paul/out/board/img.png", to: "/Users/paul/out") == "board/img.png")
        #expect(PathCopy.relative("/Users/paul/out/img.png", to: "/Users/paul/out") == "img.png")
    }

    @Test func relativeHandlesTrailingSlashBase() {
        #expect(PathCopy.relative("/Users/paul/out/img.png", to: "/Users/paul/out/") == "img.png")
    }

    @Test func relativeFallsBackToAbsoluteWhenNotUnderBase() {
        #expect(PathCopy.relative("/Users/paul/other/img.png", to: "/Users/paul/out") == "/Users/paul/other/img.png")
    }

    @Test func relativeDoesNotMatchSiblingDirPrefix() {
        // "/outside" starts with the string "/out" but is a sibling dir, not under it.
        #expect(PathCopy.relative("/Users/paul/outside/img.png", to: "/Users/paul/out") == "/Users/paul/outside/img.png")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -workspace MLXBits.xcworkspace -scheme "MLXBits Image Studio" -only-testing:"MLXBits Image StudioTests/PathCopyTests" 2>&1 | grep -E "PathCopy|error:|Compiling"`
Expected: FAIL — `PathCopy` not defined (compile error).

- [ ] **Step 3: Implement `PathCopy` in `Utilities/PathCopy.swift`**

```swift
import AppKit

/// Helpers for the "Copy Path" context-menu action: computing an image path relative to the
/// output directory, and writing a string to the pasteboard.
enum PathCopy {
    /// Returns `path` relative to `base` when `path` is under `base`; otherwise returns `path`
    /// unchanged, so a file outside the output dir still yields a usable absolute path.
    static func relative(_ path: String, to base: String) -> String {
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let prefix = trimmedBase + "/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }

    /// Writes `string` to the general pasteboard, replacing prior contents.
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -workspace MLXBits.xcworkspace -scheme "MLXBits Image Studio" -only-testing:"MLXBits Image StudioTests/PathCopyTests" 2>&1 | grep -E "PathCopy|passed|failed"`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the lint gate**

Run: `swiftformat --lint --config .swiftformat . && swiftlint lint --config .swiftlint.yml --baseline .swiftlint-baseline.json --strict`
Expected: no new violations.

- [ ] **Step 6: Commit**

```bash
git add Utilities/PathCopy.swift Tests/PathCopyTests.swift
git commit -m "feat: add PathCopy helper for relative/absolute path copy"
```

---

### Task 2: Add "Copy Path" to the 6 SwiftUI preview views

**Files (Modify):**
- `Views/PreviewPane/CompletedImageView.swift` (struct `CompletedImageView`)
- `Views/PreviewPane/StepwisePreviewView.swift` (struct `Ideogram4CompletedPreviewView`, line 235)
- `Views/ZImage/ZImagePreviewViews.swift` (struct `ZImageCompletedPreviewView`, line 126)
- `Views/Krea2/Krea2PreviewViews.swift` (struct `Krea2CompletedPreviewView`, line 126)
- `Views/PreviewPane/SeedVR2PreviewViews.swift` (struct `SeedVR2CompletedPreviewView`, line 126)
- `Views/PreviewPane/GalleryItemDetailView.swift` (struct `GalleryItemDetailView`)

**Interfaces:**
- Consumes: `PathCopy.relative(_:to:)`, `PathCopy.copy(_:)` (Task 1); `AppSettings.outputDir` via `@Environment(AppSettings.self)`.

For each of the 6 structs:
1. Add `@Environment(AppSettings.self) private var settings` to the struct's stored properties (none of the 6 have it yet — the `@Environment` in these files is on the sibling *stepwise* struct).
2. Insert this submenu directly above the existing `Button("Reveal in Finder")`, using the view's path variable (`path` inside the `if let path = job.outputPath` block for the 5 job-based views; `item.path` for `GalleryItemDetailView`):

```swift
Menu("Copy Path") {
    Button("Relative") { PathCopy.copy(PathCopy.relative(path, to: settings.outputDir)) }
    Button("Absolute") { PathCopy.copy(path) }
}
```

For `GalleryItemDetailView` (no `if let` guard — `item.path` is always non-optional), the submenu uses `item.path`:
```swift
Menu("Copy Path") {
    Button("Relative") { PathCopy.copy(PathCopy.relative(item.path, to: settings.outputDir)) }
    Button("Absolute") { PathCopy.copy(item.path) }
}
```

- [ ] **Step 1: Add `@Environment(AppSettings.self) private var settings` to all 6 structs**

Add the property to each struct's stored-property block (e.g. next to the existing `@State private var image: NSImage?`).

- [ ] **Step 2: Insert the "Copy Path" `Menu` above "Reveal in Finder" in all 6 views**

In each view's `.contextMenu`, place the submenu immediately before `Button("Reveal in Finder")`. For the 5 job-based views this is inside the existing `if let path = job.outputPath { … }` block (after its `Divider()`); for `GalleryItemDetailView` it is directly above `Button("Reveal in Finder")` (using `item.path`).

- [ ] **Step 3: Build**

Run: `xcodebuild build -workspace MLXBits.xcworkspace -scheme "MLXBits Image Studio" 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Run the lint gate**

Run: `swiftformat --lint --config .swiftformat . && swiftlint lint --config .swiftlint.yml --baseline .swiftlint-baseline.json --strict`
Expected: no new violations.

- [ ] **Step 5: Manual verification**

Run the app. For each of the 6 previews (Flux completed, Ideogram4 completed, Z-Image completed, Krea2 completed, SeedVR2 completed, and a gallery item opened in the center pane): right-click the image and confirm a "Copy Path" submenu appears directly above "Reveal in Finder" with "Relative" and "Absolute". Click "Relative" and confirm the pasteboard holds the output-dir-relative path; click "Absolute" and confirm it holds the full path.

- [ ] **Step 6: Commit**

```bash
git add Views/PreviewPane/CompletedImageView.swift Views/PreviewPane/StepwisePreviewView.swift Views/ZImage/ZImagePreviewViews.swift Views/Krea2/Krea2PreviewViews.swift Views/PreviewPane/SeedVR2PreviewViews.swift Views/PreviewPane/GalleryItemDetailView.swift
git commit -m "feat: add Copy Path submenu to center-pane preview context menus"
```

---

### Task 3: Add "Copy Path" to the gallery thumbnail menu (AppKit, single-selection only)

**Files (Modify):**
- `Views/Gallery/GalleryCollectionView.swift`
  - Add `var onCopyPath: (String, Bool) -> Void` to the `GalleryCollectionView` struct's callback block (near `onRevealInFinder`).
  - In `buildMenu(for:)` (line ~828), insert the "Copy Path" `NSMenuItem` submenu directly above the "Reveal in Finder" item (line ~884), gated on `parent.multiSelectionIds.count == 1`.
- `Views/Gallery/GenerationGalleryView.swift`
  - In the `GalleryCollectionView( … )` instantiation (line ~140), wire `onCopyPath:` using `settings.outputDir` and `PathCopy`.

**Interfaces:**
- Consumes: `PathCopy.relative(_:to:)`, `PathCopy.copy(_:)` (Task 1); `AppSettings.outputDir` (via `settings` in `GenerationGalleryView`); `parent.multiSelectionIds` (existing).
- Produces: `GalleryCollectionView.onCopyPath: (String, Bool) -> Void` — `Bool` is `isRelative` (true = relative to output dir, false = absolute).

- [ ] **Step 1: Add the `onCopyPath` callback to `GalleryCollectionView`**

In the `GalleryCollectionView` struct, next to the other action callbacks (e.g. `onRevealInFinder`), add:
```swift
var onCopyPath: (String, Bool) -> Void
```

- [ ] **Step 2: Insert the "Copy Path" submenu in `buildMenu(for:)`**

In `buildMenu(for item:)`, immediately before the line that adds "Reveal in Finder" (`menu.addItem(menuItem("Reveal in Finder") { … })`), insert:
```swift
if parent.multiSelectionIds.count == 1 {
    let copyPathMenu = NSMenu(title: "Copy Path")
    copyPathMenu.addItem(menuItem("Relative") { [weak self] in self?.parent.onCopyPath(item.path, true) })
    copyPathMenu.addItem(menuItem("Absolute") { [weak self] in self?.parent.onCopyPath(item.path, false) })
    let copyPathItem = NSMenuItem(title: "Copy Path", action: nil, keyEquivalent: "")
    copyPathItem.submenu = copyPathMenu
    menu.addItem(copyPathItem)
}
```

- [ ] **Step 3: Wire `onCopyPath` in `GenerationGalleryView`**

In the `GalleryCollectionView( … )` call, add (near the other callbacks):
```swift
onCopyPath: { path, isRelative in
    PathCopy.copy(isRelative ? PathCopy.relative(path, to: settings.outputDir) : path)
},
```

- [ ] **Step 4: Build**

Run: `xcodebuild build -workspace MLXBits.xcworkspace -scheme "MLXBits Image Studio" 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Run the lint gate**

Run: `swiftformat --lint --config .swiftformat . && swiftlint lint --config .swiftlint.yml --baseline .swiftlint-baseline.json --strict`
Expected: no new violations.

- [ ] **Step 6: Manual verification**

Run the app. In the gallery: select exactly one thumbnail and right-click it — confirm "Copy Path" appears above "Reveal in Finder" with "Relative"/"Absolute", and that clicking each copies the correct path. Then select two or more thumbnails (⌘-click) and right-click one — confirm "Copy Path" is absent while "Reveal in Finder" and the other items remain.

- [ ] **Step 7: Commit**

```bash
git add Views/Gallery/GalleryCollectionView.swift Views/Gallery/GenerationGalleryView.swift
git commit -m "feat: add Copy Path submenu to gallery thumbnail menu (single selection)"
```

---

## Self-Review
- **Spec coverage:** "Copy Path" submenu (Relative/Absolute) above "Reveal in Finder" — Tasks 2 & 3. All 6 center-pane previews — Task 2. Gallery thumbnail single-selection only — Task 3. Image path (not sidecar) — Global Constraints + all tasks use `item.path`/`job.outputPath`. Relative to output dir + absolute fallback — Task 1. ✓
- **Step scan:** Each step is one action with a checkable result; no "TBD"/"handle edge cases" lines. ✓
- **Type consistency:** `PathCopy.relative(_:to:)` and `PathCopy.copy(_:)` used identically in Tasks 2 & 3; `onCopyPath: (String, Bool)` defined in Task 3 Step 1 and consumed in Step 3. ✓
- **Review Focus:** 3 relative-path edge cases pinned to Task 1 tests; 2 gallery-selection cases pinned to Task 3 manual verification (no UI tests per project convention). ✓
- **Proportion:** Plan is ~the same length as the spec; code blocks are limited to the helper (algorithm not determined by signature) and the exact submenu copy the spec fixes. ✓

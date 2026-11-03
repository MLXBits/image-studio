# Copy Path context menu — design

## Intent
When a single image is in front of the user — in the center-pane preview, or as a
single selected gallery thumbnail — they sometimes need that file's path (to reference
it in a script, doc, or another tool). Today they must Reveal in Finder and read the
path off. Add a **"Copy Path"** context-menu submenu that copies the path directly, in
two forms: **Relative** (to the app's output directory) and **Absolute** (full path).

## Goals
- A "Copy Path" submenu with "Relative" and "Absolute" items, placed directly **above**
  the existing "Reveal in Finder" item.
- Available in **every center-pane preview** (all model families: Flux, Ideogram4,
  Z-Image, Krea2, SeedVR2, and the gallery-item detail) and in the **gallery thumbnail**
  menu.
- Copies the **image** file's path — not the sidecar `.json`.
- In the gallery, show "Copy Path" only when **exactly one** item is selected; hide it
  when two or more are selected.

## Non-goals / anti-goals
- No multi-item "copy all paths" — for multi-selection the menu is hidden, not a list.
- No new settings, no keyboard shortcut.
- No menu item in the running/stepwise previews (no final image path exists there yet).
- Not a shared SwiftUI↔AppKit menu-builder (see Approaches).

## Constraints
- `item.path` / `job.outputPath` are already the **image** file path; the sidecar is a
  derived `.json` (`MetadataSidecar.sidecarURL(for:)`). Reuse the same path the
  "Reveal in Finder" item uses — no sidecar involvement.
- The output directory is `AppSettings.outputDir` (readable) and is reachable from every
  preview view via `@Environment(AppSettings.self)`.
- The gallery menu is AppKit (`NSMenu`); the preview menus are SwiftUI (`.contextMenu`).
  Follow each surface's existing idiom — the gallery already builds submenus for
  "Move to…" and "Rating".
- The lint gate (SwiftFormat 0.64.1 + SwiftLint 0.65.1 `--strict`) and Swift Testing must
  pass.

## Approaches
- **A (chosen): shared pure helper + per-surface submenu.** One small testable function
  that computes the output-dir-relative path (falling back to the absolute path when the
  file isn't under the output dir). Each surface adds its own "Copy Path" submenu in its
  native idiom. Small, idiomatic, testable.
- **B: shared menu-builder across SwiftUI and AppKit.** Rejected — `Menu` and `NSMenu`
  are different types; a shared builder is awkward, and the only genuinely shared piece is
  the relative-path computation.
- **C: minimal (only the two originally named surfaces).** Rejected — the user wants every
  center-pane preview regardless of model, so this would leave gaps.

## Decisions (made with the user)
- **Relative base = the app's output directory.** "Relative" yields e.g.
  `board/filename.png` (or `filename.png` for the Default board). "Absolute" yields the
  full `/Users/…/…/filename.png`.
- **Scope = all 7 surfaces that already have "Reveal in Finder":**
  - Center pane: `CompletedImageView` (Flux), `Ideogram4CompletedPreviewView`,
    `ZImageCompletedPreviewView`, `Krea2CompletedPreviewView`,
    `SeedVR2CompletedPreviewView`, `GalleryItemDetailView`.
  - Gallery: `GalleryCollectionView` thumbnail menu (AppKit).
- **Gallery visibility:** show "Copy Path" only when `multiSelectionIds.count == 1`;
  hide it for multi-selection. The path copied is the right-clicked item's path.
- **Fallback:** if the image isn't under the output dir (e.g. an adopted source image),
  "Relative" copies the absolute path.

## Left to the builder
- Exact home for the helper — a pure function in `Utilities/` (e.g. `PathCopy.swift`) —
  and its unit test in `Tests/`.
- The precise submenu construction per surface (SwiftUI `Menu` vs AppKit
  `NSMenuItem.submenu`), matching surrounding style.
- Pasteboard write: `NSPasteboard.general.clearContents()` +
  `setString(_:forType: .string)`.
- Keep the "Copy Path" submenu inside the existing `if let path = …` guard so it only
  appears when there is an image.

## Verification
- `swiftformat --lint` + `swiftlint --strict` pass.
- New unit test for the relative-path helper passes (Swift Testing).
- Build succeeds; manually confirm the submenu appears above "Reveal in Finder" in each
  preview and in the single-selected gallery thumbnail, and is absent for multi-selection.

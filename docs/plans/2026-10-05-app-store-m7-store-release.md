# App Store build, milestone 7: store release — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** submit the App Store build for review as v0.17.0, with the three tips, a privacy policy, a complete listing and reviewer notes, after a TestFlight pass on a second Mac.

**Architecture:** most of the spec's milestone 7 already exists. `appstore.yml` uploads to TestFlight (milestones 3–6), and the Info.plist keys and arm64-only build are in `project.yml`. What's left is:
- **In the repo:** `PRIVACY.md`, a listing-and-review pack in `docs/appstore/` with a length checker, and the submission checklist.
- **For the owner:** App Store Connect work, decisions and clicks.
- **The release:** a `v0.17.0` tag. It ships the DMG through `release.yml`, and `appstore.yml` then builds the same tag for submission.

**Tech stack:** Markdown, Python 3 (`unittest`, standard library only), GitHub Actions, App Store Connect.

**Spec:** `docs/specs/2026-10-03-app-store-build-design.md`, §6 (App Store Connect, release workflow, review), the Decisions table, the risk table, and milestone 7. Read the spec and this plan.

**Branch:** `feature/store-release`, from `main` (at `e4873a7` or later).

### Decisions for the owner (before or during execution)

1. **EU Digital Services Act trader status: decided.** The owner has declared **non-trader** in App Store Connect (2026-10-05). The app stays on the EU storefronts. Note for the record: under the DSA a trader is anyone acting for their own business purposes, and Apple cites in-app purchases as a sign of that. Tips that unlock nothing are a grey area. The status can be changed at any time in Business ▸ Compliance.
2. **Version: decided.** Submit as **v0.17.0**, the first release with milestones 5–6. The DMG ships the same tag, so the two flavors stay in step. Task 4 drafts the release notes; the owner approves the tag push.

## Global Constraints

**Identity:**
- App Store name `MLXBits Image Studio` (reserved in milestone 3)
- Bundle ID `com.mlxbits.image-studio.appstore`
- Category Graphics & Design
- Price Free
- Available everywhere except China mainland (spec §6 step 4)

**Tips (spec §5, verbatim IDs), all Consumable:**
- `com.mlxbits.imagestudio.appstore.tip.small` ($2.99)
- `com.mlxbits.imagestudio.appstore.tip.medium` ($4.99)
- `com.mlxbits.imagestudio.appstore.tip.large` ($9.99)

The first tips are submitted together with the app version.

**Review answers (spec §6):**
- App privacy: **Data Not Collected**
- Privacy policy URL: `https://github.com/MLXBits/image-studio/blob/main/PRIVACY.md`
- Support URL: `https://github.com/MLXBits/image-studio/issues`
- Age rating: answered honestly; expect 18+ (already set in App Store Connect)

**Hardware:** Apple Silicon only (arm64), macOS 26. The listing states the realistic memory requirement: 16 GB unified memory minimum, 32 GB or more for the larger models.

**No external payment steering:** the App Store listing, screenshots and reviewer notes never mention Ko-fi, GitHub Sponsors or other ways to pay.

**App Store Connect length limits** (enforced by `scripts/check_appstore_listing.py`):

| Field | Max characters |
|---|---|
| Name | 30 |
| Subtitle | 30 |
| Promotional text | 170 |
| Keywords (comma-separated, no spaces after commas) | 100 |
| Description | 4000 |
| What's New | 4000 |
| In-app purchase display name | 30 |
| In-app purchase description | 45 |
| Review notes | 4000 |

**Secrets** are entered by the owner in their own terminal or in App Store Connect, never passed through the executor. The Team ID never goes into tracked files.

## Review Focus

1. **Listing copy over a limit** (a keyword list over 100 characters, a tip description over 45) is rejected at paste time in App Store Connect. Pinned by Task 2's checker and Task 3's run of it.
2. **Anything in the listing or reviewer notes that points at another way to pay** (Ko-fi, Sponsors) is a guideline 3.1.1 rejection. Pinned by Task 3's `grep` gate.
3. **A reviewer who can't get a first image** (no model, slow download, 8 GB Mac) rejects under 2.1. The reviewer notes name the smallest model, its download size and the memory it needs. Pinned by Task 3's content checklist.
4. **"Downloads code" under guideline 2.5.2:** the notes must say that only weights (data) are downloaded and that Python and mflux ship inside the signed bundle. Pinned by Task 3's content checklist.
5. **The privacy policy contradicting "Data Not Collected":** every network call the app makes is listed, and none sends data to the developer. Pinned by Task 1's inventory step.

---

### Task 1: Privacy policy

**Files:**
- Create: `PRIVACY.md`
- Modify: `README.md` (link it from the App Store paragraph)

**Interfaces:**
- Produces: the published URL `https://github.com/MLXBits/image-studio/blob/main/PRIVACY.md` (live after merge), used by Task 3 and Task 5.

- [ ] **Step 1: List every network call the app makes**

Run:

```bash
cd "$(git rev-parse --show-toplevel)"
grep -rn -E 'URLSession|URLRequest|"https?://' --include='*.swift' App Models Runner Stores Utilities Views | grep -v '^Tests' | cut -c1-160
grep -n -E 'requests\.|urllib|huggingface_hub|http' Resources/*.py | cut -c1-160
```

Expected:
- Hugging Face (model downloads, optional token from Keychain)
- the user-configured LM Studio, ComfyUI and OpenAI-compatible endpoints
- the GitHub releases API (`UpdateChecker`, DMG only; `isEnabled` is false in the App Store build)
- StoreKit (Apple)
- the Ko-fi and GitHub Sponsors links (DMG only, opened in the browser)

Any other host is a finding: add it to the policy, or stop and ask if it sends anything to the developer.

- [ ] **Step 2: Write `PRIVACY.md`**

```markdown
# Privacy policy

**MLXBits Image Studio** · effective 5 October 2026

MLXBits Image Studio doesn't collect, store or share any data about you. There are no accounts, no analytics, no ads, and no crash or usage reporting to the developer. Everything you make, and every prompt you type, stays on your Mac unless you send it somewhere yourself.

## What the app connects to

The app only goes online for things you ask it to do:

- **Hugging Face** (huggingface.co), to download model weights the first time you use a model. If you add a Hugging Face access token in Settings, it's kept in your Mac's Keychain and sent only to Hugging Face.
- **Servers you set up yourself**, such as LM Studio, ComfyUI or another OpenAI-compatible service, used for prompt writing or remote generation. Your prompts, and for ComfyUI your source images, go to the server you chose. That service's own privacy terms apply.
- **Apple**, when you leave a tip in the App Store version. Apple processes the payment; the developer receives no personal or payment details.
- **GitHub** (DMG version only), to check whether a newer release is available. The request carries no personal data.

Links to Ko-fi or GitHub Sponsors (DMG version only) open in your browser, where those sites' terms apply.

## Your files

Images, prompts, notepad, history and settings are stored on your Mac, in the folders you choose and in the app's own storage. Deleting the app's data or your library folder removes them; the developer has no copy.

## Children

The app can generate mature images from prompts and is rated 18+ on the App Store.

## Changes and contact

Changes to this policy are made in this file, and its history is public. Questions: open an issue at https://github.com/MLXBits/image-studio/issues.
```

If Step 1 found a host not covered above, add a bullet for it in the same style.

- [ ] **Step 3: Link it from the README**

In `README.md`, after the paragraph about tips ("Image Studio is free in both flavors…"), add:

```markdown
The app collects no data: see the [privacy policy](PRIVACY.md).
```

- [ ] **Step 4: Check the render and the links**

Run: `grep -n "PRIVACY.md" README.md && for s in "doesn't collect" 'Hugging Face' 'Keychain' 'LM Studio' 'Apple processes the payment' 'DMG version only' '18+'; do grep -q -- "$s" PRIVACY.md && echo "ok: $s" || echo "MISSING: $s"; done`
Expected: one README match, and seven `ok:` lines.

- [ ] **Step 5: Commit**

```bash
git add PRIVACY.md README.md
git commit -m "docs: privacy policy for the App Store listing"
```

---

### Task 2: Listing length checker

**Files:**
- Create: `scripts/check_appstore_listing.py`
- Test: `scripts/test_check_appstore_listing.py`

**Interfaces:**
- Produces: `python3 scripts/check_appstore_listing.py [path]` (default `docs/appstore/listing.md`). Exit 0 when every field fits, 1 with one line per over-limit field otherwise. A field is a `### <Name> (max <N>)` heading followed by a fenced `text` block; the block's content (trailing newline stripped) is what's counted. `check(markdown: str) -> list[str]` returns the problems.

- [ ] **Step 1: Write the failing test**

`scripts/test_check_appstore_listing.py`:

```python
import unittest

from check_appstore_listing import check


def field(name, limit, text):
    return f"### {name} (max {limit})\n\n```text\n{text}\n```\n"


class CheckTests(unittest.TestCase):
    def test_fields_within_limits_pass(self):
        md = field("Subtitle", 30, "Local AI images on your Mac") + field("Keywords", 100, "flux,mlx")
        self.assertEqual(check(md), [])

    def test_an_over_limit_field_is_reported_with_its_length(self):
        problems = check(field("Subtitle", 30, "x" * 31))
        self.assertEqual(problems, ["Subtitle: 31 characters, max 30"])

    def test_characters_not_bytes_are_counted(self):
        self.assertEqual(check(field("Name", 5, "café…")), [])

    def test_a_heading_without_a_block_is_reported(self):
        self.assertEqual(check("### Subtitle (max 30)\n\nno block here\n"), ["Subtitle: no text block"])

    def test_keywords_must_not_have_spaces_after_commas(self):
        self.assertEqual(check(field("Keywords", 100, "flux, mlx")), ["Keywords: space after a comma wastes a character"])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd scripts && python3 -m unittest test_check_appstore_listing -v; cd ..`
Expected: ERROR, `ModuleNotFoundError: No module named 'check_appstore_listing'`.

- [ ] **Step 3: Write the checker**

`scripts/check_appstore_listing.py`:

```python
#!/usr/bin/env python3
"""Checks App Store Connect field lengths in docs/appstore/listing.md.

A field is a `### <Name> (max <N>)` heading followed by a fenced text block.
App Store Connect counts characters, so this does too.
"""
import pathlib
import re
import sys

HEADING = re.compile(r"^### (?P<name>.+?) \(max (?P<limit>\d+)\)\s*$", re.M)
BLOCK = re.compile(r"\A\s*```text\n(?P<body>.*?)\n```", re.S)


def check(markdown: str) -> list[str]:
    problems = []
    for match in HEADING.finditer(markdown):
        name, limit = match["name"], int(match["limit"])
        block = BLOCK.match(markdown[match.end():])
        if not block:
            problems.append(f"{name}: no text block")
            continue
        body = block["body"]
        if len(body) > limit:
            problems.append(f"{name}: {len(body)} characters, max {limit}")
        if name == "Keywords" and ", " in body:
            problems.append("Keywords: space after a comma wastes a character")
    return problems


def main() -> int:
    path = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "docs/appstore/listing.md")
    problems = check(path.read_text(encoding="utf-8"))
    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run it to verify it passes**

Run: `cd scripts && python3 -m unittest test_check_appstore_listing -v; cd ..`
Expected: 5 tests OK.

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/check_appstore_listing.py
git add scripts/check_appstore_listing.py scripts/test_check_appstore_listing.py
git commit -m "Listing length checker for App Store Connect fields"
```

---

### Task 3: Listing, tips and reviewer notes

**Files:**
- Create: `docs/appstore/listing.md`

**Interfaces:**
- Consumes: `scripts/check_appstore_listing.py` (Task 2), the privacy URL (Task 1).
- Produces: every text field the owner pastes into App Store Connect, in one file.

- [ ] **Step 1: Write `docs/appstore/listing.md`**

````markdown
# App Store listing — MLXBits Image Studio

Paste each block into App Store Connect as is. `python3 scripts/check_appstore_listing.py` checks every length; run it after any edit.

## App information

### Name (max 30)

```text
MLXBits Image Studio
```

### Subtitle (max 30)

```text
Local AI images on your Mac
```

- **Category:** Graphics & Design (secondary: none)
- **Privacy policy URL:** https://github.com/MLXBits/image-studio/blob/main/PRIVACY.md
- **Support URL:** https://github.com/MLXBits/image-studio/issues
- **Marketing URL:** https://github.com/MLXBits/image-studio
- **Copyright:** © 2026 MLXBits

## Version page

### Promotional text (max 170)

```text
Generate images with FLUX.2, Krea 2 and Z-Image entirely on your Mac. No account, no cloud, no subscription. Every feature is free.
```

### Keywords (max 100)

```text
flux,ai image,image generator,text to image,mlx,lora,offline,local ai,krea,z-image,art,generative
```

### Description (max 4000)

```text
MLXBits Image Studio turns text into images on your Mac, using Apple's MLX framework and the Apple silicon GPU. Nothing is sent to a server: your prompts and pictures stay on your Mac.

GENERATE
• FLUX.2 Klein (4B and 9B), Krea 2 and Z-Image Turbo, with quantized versions for Macs with less memory
• Image editing and image-to-image with your own photos
• LoRAs from any folder, saved as one-click stacks
• A queue: line up dozens of prompts and walk away

SEE IT HAPPEN
• Watch each image take shape step by step
• Keep the model loaded between runs, so back-to-back images skip the load

ORGANISE
• A fast gallery with boards, ratings, flags and side-by-side comparison
• Profiles keep separate libraries, prompts and history, for example personal and work
• Every image remembers its prompt, seed and settings

WRITE BETTER PROMPTS
• Templates, wildcards, a notepad and prompt history
• An optional local language model (Gemma) that writes and varies prompts for you, also on-device

REQUIREMENTS
• A Mac with Apple silicon (M1 or later) and macOS 26
• 16 GB of unified memory or more; 32 GB or more for the larger models
• Model weights download from Hugging Face the first time you use a model (about 8 GB for the smallest). Point the app at an existing Hugging Face folder and it reuses what you already have.

FREE
Every feature is free. Optional tips help keep the project going and unlock nothing.

The app can create mature images from your prompts and has no content filter, so it is rated 18+.
```

### What's New (max 4000)

```text
First App Store release.
```

## In-app purchases

All three are Consumable. Each gets the same review screenshot: the Support window, with tips loaded, over the main window (SFW profile).

### Small Tip display name (max 30)

```text
Small Tip
```

### Small Tip description (max 45)

```text
A small thank-you. Unlocks nothing.
```

### Medium Tip display name (max 30)

```text
Medium Tip
```

### Medium Tip description (max 45)

```text
A medium thank-you. Unlocks nothing.
```

### Large Tip display name (max 30)

```text
Large Tip
```

### Large Tip description (max 45)

```text
A large thank-you. Unlocks nothing.
```

### Tip review notes (max 4000)

```text
A tip to support the developer. It is a consumable that unlocks no features or content. Open it from the app menu: MLXBits Image Studio ▸ Support MLXBits Image Studio…, or Settings ▸ Advanced ▸ Support. The same window offers all three tips.
```

## App Review

### Review notes (max 4000)

```text
MLXBits Image Studio generates images on-device with Apple MLX. It needs Apple silicon and at least 16 GB of unified memory.

FIRST IMAGE (about 10 minutes, mostly the download)
1. On first launch, choose a library folder or click Skip for Now (it uses Pictures ▸ MLXBits Image Studio).
2. On the models step, click Keep Models in the App (or Continue).
3. In the model menu at the top left, choose FLUX.2 Klein 4B and set quantization to Q8.
4. Type a prompt, for example "a red fox in fresh snow, morning light", and click Generate.
The first run downloads the model weights from Hugging Face, about 8 GB, with progress shown. Later runs take seconds.

BUNDLED CODE (guideline 2.5.2)
The app ships its own Python 3.14 runtime with the open-source mflux and MLX libraries inside the signed app bundle; every executable is signed and sandboxed with the app. The app downloads only model weights (safetensors data files) from Hugging Face. It never downloads or runs code from outside its bundle.

NETWORK
Hugging Face for model weights. Optionally, servers the user sets up on their own network (LM Studio, ComfyUI) or an OpenAI-compatible service, used only when configured in Settings. Nothing is sent to the developer; the app collects no data.

TIPS
Three consumable in-app purchases in the Support window (app menu ▸ Support MLXBits Image Studio…). They unlock nothing; every feature is free.

CONTENT
Images are generated from the user's own prompts, locally, with no content filter. The app is rated 18+ accordingly, as are comparable apps such as Draw Things.
```

## Age rating answers

Answer honestly; these are the expected answers. The app is already set to 18+.
- **Sexual content or nudity:** frequent or intense (it can generate such images on request; there's no filter)
- **Graphic violence, horror, mature themes:** infrequent or mild (possible on request)
- **User-generated content shared with others:** no (nothing is shared or uploaded)
- **Unrestricted web access:** no
- **Gambling, contests, alcohol and drugs, medical:** no

## App privacy answers

- **Data collection:** "No, we do not collect data from this app."
- Tips are processed by Apple; the developer doesn't receive purchase data that counts as collection.

## Screenshots

- **Size:** 2880×1800 (or 2560×1600), Mac. Up to 10; the first three matter most.
- **Profile:** SFW, with a clean prompt box and gallery.

1. The main window: a finished image, the params panel and a full gallery.
2. Step-by-step preview mid-generation.
3. The gallery's compare view or boards with ratings.
4. The LoRA manager with a stack.
5. The Scenario Generator writing prompts.

No Ko-fi, GitHub or other payment links in any shot.
````

- [ ] **Step 2: Check the lengths**

Run: `python3 scripts/check_appstore_listing.py`
Expected: no output, exit 0. If a field is over, shorten the copy, not the limit.

- [ ] **Step 3: Check for payment steering and the required content**

Run:

```bash
grep -n -i -E 'ko-?fi|sponsor|paypal|patreon|donat' docs/appstore/listing.md; echo "steering-grep-exit=$?"
for s in '16 GB' 'FLUX.2 Klein 4B' 'about 8 GB' 'never downloads or runs code' 'unlock nothing' 'PRIVACY.md' '18+'; do grep -q -- "$s" docs/appstore/listing.md && echo "ok: $s" || echo "MISSING: $s"; done
```

Expected: `steering-grep-exit=1` (no matches), and seven `ok:` lines.

- [ ] **Step 4: Verify the reviewer path in the code**

Check that the reviewer steps match the app:
- `grep -n "Skip for Now" Views/Settings/OutputDirectoryPromptView.swift`
- `grep -n "Keep Models in the App" Views/Settings/ModelsFolderStepView.swift`
- `grep -n "flux2-klein-4b-8bit" Models/FluxModelCatalog.swift`
- `grep -n "approximateBF16SizeGB" -A3 Models/FluxModelCatalog.swift`. Klein 4B is 15 GB at BF16, so Q8 is about 8.

Expected: all four found, and the 8 GB figure agrees. If a label differs, fix the notes, not the app.

- [ ] **Step 5: Commit**

```bash
git add docs/appstore/listing.md
git commit -m "docs: App Store listing, tips and reviewer notes"
```

---

### Task 4: Submission checklist, release notes, spec

**Files:**
- Create: `docs/appstore/submission.md`
- Create: `docs/appstore/release-notes-v0.17.0.md`
- Modify: `docs/specs/2026-10-03-app-store-build-design.md` (milestone 7: point at `docs/appstore/`)
- Modify: `README.md` ("App Store builds" section: link `docs/appstore/submission.md`)

**Interfaces:**
- Consumes: `docs/appstore/listing.md` (Task 3), `PRIVACY.md` (Task 1).
- Produces: the ordered owner checklist that Task 5 walks through.

- [ ] **Step 1: Write `docs/appstore/submission.md`**

```markdown
# Submitting MLXBits Image Studio to the App Store

The owner's checklist, in order. Text to paste lives in [listing.md](listing.md).

## Before the build
1. **Agreements:** App Store Connect ▸ Business: the Paid Applications agreement is active, with bank and tax details. Tips can't be sold without it.
2. **Small Business Program:** enrolled (15% commission). Apply at developer.apple.com/app-store/small-business-program.
3. **EU Digital Services Act:** Business ▸ Compliance. Declared non-trader (owner's decision, 2026-10-05); revisit if the app becomes commercial beyond tips.
4. **Tips:** Monetization ▸ In-App Purchases ▸ +, three times, Consumable, with the IDs, names, descriptions, review notes and screenshot from listing.md. Prices: $2.99, $4.99, $9.99 (US base; App Store Connect fills other storefronts).

## The build
5. **Release:** `git tag v0.17.0 && git push origin v0.17.0` ships the DMG through release.yml. Then `gh workflow run appstore.yml` (no ref: it builds the newest tag) uploads 0.17.0 to TestFlight.
6. **Availability:** Pricing and Availability: Free, all countries except China mainland.

## TestFlight pass (a second Mac)
7. Install 0.17.0 from TestFlight and check:
   - first run: library and models steps
   - one FLUX.2 Klein 4B Q8 image
   - Support ▸ the three tips load with prices
   - buy one tip: TestFlight purchases use your own Apple Account and are never charged. Expect the thank-you, and the nudge never shows after
8. **Runtime check:** run `"/Applications/MLXBits Image Studio.app/Contents/MacOS/MLXBits Image Studio" --runtime-self-test` (the TestFlight copy's path may differ, for example "MLXBits Image Studio 2.app"). Expect "Runtime self-test passed".

## The listing
9. **App information:** name, subtitle, category, privacy policy URL and support URL from listing.md.
10. **Version 0.17.0 page:** promotional text, description, keywords, What's New, screenshots, support and marketing URLs, copyright.
11. **App privacy:** Data Not Collected. Publish it.
12. **Age rating:** answers from listing.md; confirm 18+.

## Submit
13. On the version page, select build 0.17.0 and, under In-App Purchases, add all three tips.
14. Paste the review notes. Sign-in required: no.
15. **Release:** choose manual release, so you pick the moment after approval.
16. Click Add for Review, then Submit for Review.

## If App Review asks questions
- **Guideline 2.5.2 (downloaded code):** the review notes' "Bundled code" paragraph. Only weights are downloaded.
- **Guideline 1.2/1.1 (content):** the app makes images only from the user's own prompts, on-device, rated 18+, like Draw Things.
- **Guideline 2.1 (couldn't test):** a small model, 16 GB Mac, about 8 GB download. Offer a screen recording of a first run if asked.
```

- [ ] **Step 2: Write `docs/appstore/release-notes-v0.17.0.md`**

Collect the changes since v0.16.0:

Run: `git log --oneline v0.16.0..main | cat`

Write the notes in the style of the v0.16.0 release body (`gh release view v0.16.0 --json body --jq .body`). Group them:
- **New:** the App Store build's sandbox file access (models folder step, Pictures default, remembered folders and LoRAs); the Support window, with tips in the App Store build and Ko-fi in the DMG; the one-time nudge.
- **Fixed:** models in a chosen Hugging Face folder are found; Gemma downloads run outside the Scenario panel with progress (#18, partly); first-run buttons look like buttons; Locate… fixes for LoRAs.
- **Developers:** Metal API Validation is off in the run schemes; StoreKitTest is skipped on CI.

Every user-facing line must be true of the DMG. Mark App Store-only items "(App Store version)".

- [ ] **Step 3: Point the spec and README at the pack**

- In the spec's milestone 7 entry, add: "Listing, reviewer notes, tips and the submission checklist: `docs/appstore/`."
- In README's "App Store builds" section, add: "Submitting a version: see [docs/appstore/submission.md](docs/appstore/submission.md)."

- [ ] **Step 4: Verify**

Run: `python3 scripts/check_appstore_listing.py && grep -n "docs/appstore" README.md docs/specs/2026-10-03-app-store-build-design.md`
Expected: exit 0, and two matches.

- [ ] **Step 5: Commit**

```bash
git add docs/appstore/submission.md docs/appstore/release-notes-v0.17.0.md README.md docs/specs/2026-10-03-app-store-build-design.md
git commit -m "docs: App Store submission checklist and v0.17.0 release notes"
```

---

### Task 5: Merge, release, submit (owner-gated)

Every step here is outward-facing. The executor prepares, and the owner approves each step.

- [ ] **Step 1: Open the PR and merge**

Push `feature/store-release`, open a PR (no AI attribution), and wait for CI and CodeRabbit. Merge with the owner's go-ahead. After the merge, the privacy policy URL is live; open it in a browser to confirm.

- [ ] **Step 2: Owner decisions**

Ask the owner for:
- approval to tag `v0.17.0`, with the release notes from Task 4 as the body.

- [ ] **Step 3: Tag and release**

On approval:

```bash
git checkout main && git pull
git tag v0.17.0 && git push origin v0.17.0
gh run watch "$(gh run list --workflow release.yml --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
gh release edit v0.17.0 --notes-file docs/appstore/release-notes-v0.17.0.md
gh workflow run appstore.yml
```

Expected: release.yml green, the DMG published under v0.17.0 with the notes, and appstore.yml green, uploading 0.17.0 (build `<commit count>.<run>`).

- [ ] **Step 4: Hand off to the owner**

Give the owner `docs/appstore/submission.md`, starting at step 1 (or step 6 if steps 1–4 are done). Stay available for questions App Review sends back.

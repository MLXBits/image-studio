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

## TestFlight pass (selphie)
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

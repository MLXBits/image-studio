**Support the project, if you like.** Every feature stays free. A new Support window (app menu ▸ Support MLXBits Image Studio…, also in Settings ▸ Advanced) links to Ko-fi. After your 50th image the app asks once, and never again.

**Also new:**
- **Gemma downloads run in the app.** The Scenario Generator's first-use Gemma download now shows progress and keeps going when you close the panel (part of #18).
- **Fewer outside requests.** The bundled Hugging Face tools no longer check PyPI for updates or add usage details to their requests. The app collects no data: see [PRIVACY.md](https://github.com/MLXBits/image-studio/blob/main/PRIVACY.md).

**Fixed:**
- Models in a Hugging Face folder you chose in Settings are found, instead of showing as not downloaded.
- Skip for Now on the first-run library screen now looks like a button.

**Known issue:** Ideogram 4's Q8 and Q4 downloads don't load yet (#20). Use FP8 for now.

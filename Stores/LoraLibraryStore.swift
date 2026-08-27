import Foundation

/// Persistent catalog of curated ``LibraryLora`` entries and saved ``LoraStack``
/// combos. Kept separate from ``AppSettings`` (already large) since it's a
/// distinct domain; persisted to its own `lora-library.json` in the shared app
/// support directory.
///
/// Injected into the SwiftUI environment at the app root and read via
/// `@Environment(LoraLibraryStore.self)`.
@Observable
final class LoraLibraryStore {
    private struct Stored: Codable {
        var library: [LibraryLora]?
        var stacks: [LoraStack]?
    }

    private static let fileURL: URL =
        AppSettings.appSupportURL.appendingPathComponent("lora-library.json")

    var library: [LibraryLora] {
        didSet { save() }
    }

    var stacks: [LoraStack] {
        didSet { save() }
    }

    /// Set to a human-readable message when ``save()`` fails; cleared on the next
    /// successful save.
    var saveError: String?

    /// Default-flagged entries across all families; observed by ContentView to
    /// react when the default set (or a default's notes/strength) changes.
    var allDefaultLoras: [LoraEntry] {
        library.filter(\.isDefault).map { $0.toEntry() }
    }

    @ObservationIgnored private let saveDebouncer = Debouncer()

    init() {
        let stored: Stored = {
            guard let data = try? Data(contentsOf: Self.fileURL) else { return Stored() }
            return (try? JSONDecoder().decode(Stored.self, from: data)) ?? Stored()
        }()
        library = stored.library ?? []
        stacks = stored.stacks ?? []
    }

    // MARK: - Queries

    /// Library entries for `family`, sorted by display name.
    func entries(for family: ModelFamily) -> [LibraryLora] {
        library
            .filter { $0.modelFamily == family }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Library entries visible in a picker for `family`, given whether that family currently routes generation to a
    /// ComfyUI server. When `routedToComfyUI` is true, only auto-cataloged server LoRAs (``LibraryLora/isServerLoRA``)
    /// are returned — local-disk entries are meaningless on the remote box and would be submitted as unresolvable paths.
    /// When false, all entries for the family return (the normal mflux case). This is the single "hide local / show remote"
    /// gate: pickers call this instead of ``entries(for:)`` so behavior stays consistent across every surface.
    func visibleEntries(for family: ModelFamily, routedToComfyUI: Bool) -> [LibraryLora] {
        let all = entries(for: family)
        guard routedToComfyUI else { return all }
        return all.filter(\.isServerLoRA)
    }

    /// Saved stacks for `family`, sorted by display name.
    func stacks(for family: ModelFamily) -> [LoraStack] {
        stacks
            .filter { $0.modelFamily == family }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// The library entry matching `path` (identity key), if cataloged.
    func libraryEntry(path: String) -> LibraryLora? {
        library.first { $0.path == path }
    }

    /// Per-job entries for every default-flagged library LoRA of `family`,
    /// at their library strength. This is the single source of the "default
    /// LoRAs" applied to new generations.
    func defaultLoras(for family: ModelFamily) -> [LoraEntry] {
        entries(for: family).filter(\.isDefault).map { $0.toEntry() }
    }

    // MARK: - Server LoRA cataloging (ComfyUI)

    /// Auto-catalogs a batch of server-side LoRA names from a ComfyUI `/models/loras` discovery pass into this library,
    /// one ``LibraryLora`` per name whose base model the heuristic could confidently place. Names that don't match any
    /// image family (e.g. video-model LoRAs) are *not* auto-added — they surface in the "Unclassified" group for manual
    /// placement instead, so we never force a wrong base-model assignment onto user-visible state.
    ///
    /// Idempotent: an existing entry keyed by `path` (the full relative name) is left completely untouched, so any SFW/NSFW
    /// rating, default strength, tags, or trigger words the user set on a previous run survive re-discovery. Only names that
    /// have never been cataloged are inserted here, with a sensible default strength and an `.unrated` rating to nudge the
    /// user to classify content they'll actually use. Returns the number of *new* entries added (0 when everything is known).
    @discardableResult
    func catalogServerLoras(names: [String]) -> Int {
        var added = 0
        for name in names {
            guard !name.isEmpty else { continue }
            // Identity key is the full relative path exactly as `/models/loras` returned it (e.g. `krea2/foo.safetensors`).
            // ComfyUI guarantees these are unique server-side, so no basename-collision handling is needed here; using the
            // verbatim name also means submission to a `LoraLoader.lora_name` node needs zero transformation later.
            if libraryEntry(path: name) != nil {
                continue
            }
            guard let family = LoraBaseModelHeuristic.guess(for: name).family else { continue }
            // Display name is the basename (path component after the last slash) so `krea2/Foo.safetensors` reads "Foo"
            // in the picker, not a path. The full relative path stays as the identity / submission key on `.path`.
            let base = (name as NSString).lastPathComponent
            library.append(LibraryLora(
                name: base,
                path: name,
                modelFamily: family,
                defaultStrength: 1.0,
                rating: .unrated,
                isServerLoRA: true
            ))
            added += 1
        }
        return added
    }

    // MARK: - Mutations

    func upsert(_ entry: LibraryLora) {
        if let idx = library.firstIndex(where: { $0.id == entry.id }) {
            library[idx] = entry
        } else {
            library.append(entry)
        }
    }

    func deleteLibrary(id: UUID) {
        library.removeAll { $0.id == id }
    }

    func upsert(_ stack: LoraStack) {
        if let idx = stacks.firstIndex(where: { $0.id == stack.id }) {
            stacks[idx] = stack
        } else {
            stacks.append(stack)
        }
    }

    func deleteStack(id: UUID) {
        stacks.removeAll { $0.id == id }
    }

    // MARK: - Legacy migration

    /// One-time fold of the pre-library `AppSettings.defaultLoras` list into
    /// `LibraryLora.isDefault` flags, cataloging any entry not yet in the
    /// library. Drains the legacy list so it never reapplies.
    func migrateLegacyDefaults(from settings: AppSettings) {
        let legacy = settings.drainLegacyDefaultLoras()
        guard !legacy.isEmpty else { return }
        for entry in legacy {
            if let idx = library.firstIndex(
                where: { $0.path == entry.path && $0.modelFamily == entry.modelFamily }
            ) {
                library[idx].isDefault = true
                library[idx].defaultStrength = entry.strength
            } else {
                library.append(LibraryLora(
                    path: entry.path,
                    modelFamily: entry.modelFamily,
                    defaultStrength: entry.strength,
                    notes: entry.notes,
                    isDefault: true
                ))
            }
        }
    }

    // MARK: - Persistence

    private func save() {
        saveDebouncer.schedule { [weak self] in self?.saveNow() }
    }

    private func saveNow() {
        let stored = Stored(library: library, stacks: stacks)
        do {
            try FileManager.default.createDirectory(
                at: AppSettings.appSupportURL, withIntermediateDirectories: true
            )
            let enc = JSONEncoder()
            enc.outputFormatting = .prettyPrinted
            let data = try enc.encode(stored)
            try data.write(to: Self.fileURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = "Could not save LoRA library: \(error.localizedDescription)"
        }
    }
}

// MARK: - Trigger words

/// Appends any trigger phrase from `triggers` not already present in `prompt`
/// (case-insensitive), comma-joined onto the end. No-op for empty triggers.
/// Trigger phrases are split on commas so a multi-phrase field only adds the
/// parts that are missing.
func insertTriggerWords(_ triggers: String, into prompt: String) -> String {
    let phrases = triggers
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard !phrases.isEmpty else { return prompt }

    let lowerPrompt = prompt.lowercased()
    let missing = phrases.filter { !lowerPrompt.contains($0.lowercased()) }
    guard !missing.isEmpty else { return prompt }

    let addition = missing.joined(separator: ", ")
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return addition
    }
    let separator = trimmed.hasSuffix(",") ? " " : ", "
    return trimmed + separator + addition
}

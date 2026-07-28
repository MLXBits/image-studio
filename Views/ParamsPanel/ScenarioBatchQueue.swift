import SwiftUI

// Batch-queue half of the scenario generator: roll one prompt per image, then hand
// them all to the params panel as one job apiece.
//
// This replaces the old Generate → Use → Generate loop, which had to be repeated by
// hand for every image. Rolling all N prompts up front (rather than interleaving with
// image generation) loads the LLM once and — on the local backend — releases it again
// before mflux pulls Flux into memory.

/// The counts the Queue menu offers, and how a remembered choice resolves against them.
/// Pure and settings-free so the clamping is testable.
enum ScenarioQueueCounts {
    /// Mirrors the main Generate button's list, with 1 prepended: a single
    /// roll-and-queue is the one-click replacement for the old manual loop.
    /// `preset == 0` means the user configured a custom batch size, which is appended.
    static func options(preset: Int, customCount: Int) -> [Int] {
        [1, 3, 5, 10] + (preset == 0 ? [customCount] : [])
    }

    /// The count a plain click uses: the last one picked, unless it is no longer on
    /// offer — a custom size that has since been edited away would otherwise strand
    /// the button on a number its menu can't reach.
    static func resolve(stored: Int, options: [Int]) -> Int {
        options.contains(stored) ? stored : (options.first ?? 1)
    }
}

extension ScenarioGeneratorView {
    // MARK: - Footer control

    /// "Queue N" plus a count menu, built from the same pieces as the main Generate
    /// button (plain button + hairline + ``BatchMenuButton``) so the two batch
    /// affordances look and behave alike.
    ///
    /// After a cancelled or failed run the prompts that did land are still held, so
    /// the button switches to offering just those rather than discarding them.
    var queueControl: some View {
        let held = session.batchPrompts.count
        let canQueue = !session.isGenerating
            && !session.outline.trimmingCharacters(in: .whitespaces).isEmpty
        let enabled = held > 0 ? !session.isGenerating : canQueue
        return HStack(spacing: 0) {
            Button {
                if held > 0 { flushHeldPrompts() } else { startBatchQueue(count: queueCount) }
            } label: {
                Text("Queue \(held > 0 ? held : queueCount)")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            if held == 0 {
                Rectangle()
                    .fill(.white.opacity(0.35))
                    .frame(width: 1, height: 14)
                BatchMenuButton(
                    counts: queueCountOptions,
                    // 0 claims no key equivalent: ⌘⌥↵ belongs to the main Generate
                    // button, and showing it here would advertise a shortcut that
                    // doesn't reach this panel.
                    shortcutCount: 0,
                    isDisabled: !canQueue,
                    verb: "Queue"
                ) { count in
                    settings.scenarioQueueCount = count
                    startBatchQueue(count: count)
                }
                .frame(width: 24, height: 24)
            }
        }
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor))
        .opacity(enabled ? 1.0 : 0.5)
        .focusEffectDisabled()
        .help(held > 0
            ? "Queue the \(held) prompt\(held == 1 ? "" : "s") already rolled"
            : "Roll one prompt per image, then queue them")
    }

    var queueCountOptions: [Int] {
        ScenarioQueueCounts.options(
            preset: settings.batchShortcutPreset,
            customCount: settings.batchShortcutCustomCount
        )
    }

    var queueCount: Int {
        ScenarioQueueCounts.resolve(stored: settings.scenarioQueueCount, options: queueCountOptions)
    }

    // MARK: - Actions

    /// Rolls `count` prompts back to back, then hands them all to `onQueue`.
    func startBatchQueue(count: Int) {
        let session = session
        session.isGenerating = true
        session.generateError = nil
        session.batchPrompts = []
        session.rollTarget = count
        session.task = Task {
            var failure: String?
            for _ in 0 ..< count {
                if Task.isCancelled { break }
                do {
                    session.result = try await rollOne(session: session)
                    session.batchPrompts.append(session.result)
                } catch is CancellationError {
                    break
                } catch {
                    // Keep whatever already landed — one bad roll shouldn't cost the batch.
                    failure = error.localizedDescription
                    break
                }
            }
            let complete = failure == nil && !Task.isCancelled && session.batchPrompts.count == count
            session.lastGemmaLog = session.generator.lastLog
            session.generateError = failure
            session.isGenerating = false
            session.rollTarget = 0
            session.task = nil
            // Free the local model before the image jobs start loading theirs. A no-op
            // on the remote backend, where LM Studio owns the model.
            session.generator.shutdown()
            if complete { flushHeldPrompts() }
        }
    }

    /// Hands the rolled prompts over and clears them. Called automatically after a
    /// clean run, or from the footer after a cancelled or failed one.
    func flushHeldPrompts() {
        let prompts = session.batchPrompts
        session.batchPrompts = []
        guard !prompts.isEmpty else { return }
        onQueue(prompts)
    }

    /// One roll for a batch. Wildcard mode is off — Queue's variety comes from rolling
    /// afresh — and an exact repeat is re-rolled once, cheap insurance against a low
    /// temperature collapsing the whole batch onto a single prompt.
    private func rollOne(session: ScenarioSession) async throws -> String {
        let first = try await roll(session)
        guard session.batchPrompts.contains(first) else { return first }
        return try await roll(session) // one re-roll, then take what we get
    }

    private func roll(_ session: ScenarioSession) async throws -> String {
        try await session.generator.generate(
            outline: session.outline,
            categories: session.categories,
            wildcardMode: false,
            settings: settings
        )
    }
}

import Foundation

/// One Generate press: checks the active family's form, remembers it in
/// settings for the next launch, and queues its jobs. Holds references only:
/// ``ContentView`` builds one from its state as needed.
struct GenerateAction {
    let settings: AppSettings
    let forms: FamilyForms
    let queues: FamilyQueues
    let families: FamilyRegistry

    /// The active family's prompt field, for ``PromptBatchSplitter``. Nil for
    /// Ideogram 4, whose caption is a structured document with no per-prompt path.
    private var batchablePromptField: String? {
        switch forms.flux.modelFamily {
        case .flux: forms.flux.prompt
        case .krea2: forms.krea2.prompt
        case .zimage: forms.zimage.prompt
        case .qwen21: forms.qwen21.prompt
        case .ideogram4, .seedvr2: nil
        }
    }

    /// Keeps the prompts typed but not yet generated with the current profile.
    /// Generating saves these too; this covers leaving the profile first.
    func saveContentDrafts() {
        settings.lastPrompt = forms.flux.prompt
        settings.lastLoras = forms.flux.loras
        settings.lastKrea2 = forms.krea2.snapshot()
        settings.lastZImage = forms.zimage.snapshot()
        settings.lastQwen21 = forms.qwen21.snapshot()
    }

    /// Queues the press's jobs. `scenarioPrompts`, when supplied, is a batch of
    /// prompts independently rolled by the scenario generator — each becomes its
    /// own job, bypassing the prompt field and wildcard fan-out. A wildcard group
    /// in a scenario prompt is still resolved, to one sampled option.
    ///
    /// Returns the first job's preview when every queue was idle, for the preview
    /// pane to follow; nil when nothing was queued or other work runs first.
    func callAsFunction(count: Int = 1, scenarioPrompts: [String]? = nil) -> PreviewState? {
        // Several prompts pasted into the field, split by `---` lines, queue one job
        // each — the same one-job-per-prompt shape as a scenario batch.
        if scenarioPrompts == nil, let field = batchablePromptField {
            let prompts = PromptBatchSplitter.split(field)
            if prompts.count > 1 {
                if forms.flux.modelFamily == .flux {
                    settings.lastPrompt = field
                }
                settings.recordPromptUse(field)
                return self(count: prompts.count, scenarioPrompts: prompts)
            }
        }

        // Remember the custom checkpoint and the family it loads as, so the
        // selection is intact on relaunch. Each family below sets `lastModel`;
        // these two are what make `.custom` mean something again.
        if forms.flux.model == .custom {
            settings.lastCustomModelRepo = forms.flux.customModelRepo
            settings.lastCustomBaseModel = forms.flux.customBaseModel
        }

        switch forms.flux.modelFamily {
        case .flux: return generateFlux(count: count, scenarioPrompts: scenarioPrompts)
        case .ideogram4: return generateIdeogram4(count: count)
        case .krea2: return generateKrea2(count: count, scenarioPrompts: scenarioPrompts)
        case .zimage: return generateZImage(count: count, scenarioPrompts: scenarioPrompts)
        case .qwen21: return generateQwen21(count: count, scenarioPrompts: scenarioPrompts)
        case .seedvr2: return nil // upscaler — never the picker-selected family; started via startUpscale
        }
    }

    // MARK: - Families

    private func generateFlux(count: Int, scenarioPrompts: [String]?) -> PreviewState? {
        // A scenario batch brings its own prompts, so an empty prompt field is fine.
        guard scenarioPrompts?.isEmpty == false || !forms.flux.prompt.trimmingCharacters(in: .whitespaces).isEmpty,
              !forms.flux.isEditMode || !forms.flux.editImagePaths.isEmpty else { return nil }
        if scenarioPrompts == nil {
            // Skip for scenario batches: N rolled prompts would swamp the history,
            // and each image's sidecar already records the prompt it used.
            settings.lastPrompt = forms.flux.prompt
            settings.recordPromptUse(forms.flux.prompt)
        }
        settings.lastWidth = forms.flux.width
        settings.lastHeight = forms.flux.height
        settings.lastLoras = forms.flux.loras
        settings.lastModel = forms.flux.model
        settings.lastQuantize = forms.flux.quantize
        // Low RAM lives in Settings -> Models; read it now so a toggle applies to
        // this run instead of only after a relaunch.
        forms.flux.applyMemoryDefaults(from: settings)
        let constraints: DimensionConstraints = forms.flux.model.isFlux ? .flux2 : .legacy
        let jobs = PromptFanOut.jobs(prompt: forms.flux.prompt, scenarioPrompts: scenarioPrompts, count: count) {
            forms.flux.templatedPrompts(templates: settings.activeTemplates, overriding: $0)
        }.map {
            forms.flux.makeJob(
                count: $0.count,
                resolvedPrompt: ($0.positive, $0.negative),
                size: AspectDirective.size(ratio: $0.ratio, width: forms.flux.width, height: forms.flux.height, constraints: constraints)
            )
        }
        return queue(jobs, on: families.flux)
    }

    private func generateIdeogram4(count: Int) -> PreviewState? {
        guard forms.ideogram4.canGenerate else { return nil }
        // Remember the picker selection across sessions — `custom` must survive
        // as itself, not be flattened to the family it happens to load as.
        settings.lastModel = forms.flux.model == .custom ? .custom : .ideogram4
        settings.lastIdeogramPreset = forms.ideogram4.preset
        settings.lastIdeogramWidth = forms.ideogram4.width
        settings.lastIdeogramHeight = forms.ideogram4.height
        settings.lastIdeogramQuantize = forms.ideogram4.quantize
        settings.lastIdeogramCaption = forms.ideogram4.caption
        settings.lastIdeogramPlainPrompt = forms.ideogram4.plainPrompt
        settings.lastIdeogramUsePlainPrompt = forms.ideogram4.usePlainPrompt
        settings.lastIdeogramSeed = forms.ideogram4.seed
        // Low-RAM and strict-validation live in Settings → Models → Ideogram;
        // pull the current values so live edits apply to this run.
        forms.ideogram4.lowRam = settings.ideogram4LowRam
        forms.ideogram4.strictValidation = settings.ideogram4StrictValidation
        let job = forms.ideogram4.makeJob(count: count, customModelRepo: forms.flux.effectiveCustomRepo)
        return queue([job], on: families.ideogram4)
    }

    private func generateKrea2(count: Int, scenarioPrompts: [String]?) -> PreviewState? {
        guard forms.krea2.canGenerate || scenarioPrompts?.isEmpty == false else { return nil }
        // Remember the picker selection across sessions — `custom` must survive as
        // itself, not be flattened to the family it happens to load as.
        settings.lastModel = forms.flux.model == .custom ? .custom : .krea2
        settings.lastKrea2 = forms.krea2.snapshot() // remember the form across launches
        // Low-RAM lives in Settings → Models → Krea 2; pull it so live edits apply to this run.
        forms.krea2.lowRam = settings.resolvedDefaults(for: .krea2).lowRam
        if scenarioPrompts == nil {
            settings.recordPromptUse(forms.krea2.prompt)
        }
        let jobs = PromptFanOut.jobs(prompt: forms.krea2.prompt, scenarioPrompts: scenarioPrompts, count: count) {
            ($0, forms.krea2.negativePrompt)
        }.map {
            forms.krea2.makeJob(
                count: $0.count,
                customModelRepo: forms.flux.effectiveCustomRepo,
                resolvedPrompt: ($0.positive, $0.negative),
                size: AspectDirective.size(
                    ratio: $0.ratio, width: forms.krea2.width, height: forms.krea2.height, constraints: .krea2
                )
            )
        }
        return queue(jobs, on: families.krea2)
    }

    private func generateZImage(count: Int, scenarioPrompts: [String]?) -> PreviewState? {
        guard forms.zimage.canGenerate || scenarioPrompts?.isEmpty == false else { return nil }
        // Remember the picker selection across sessions — `custom` must survive as
        // itself, not be flattened to the variant it happens to load as.
        settings.lastModel = forms.flux.model == .custom ? .custom : forms.zimage.variant
        settings.lastZImage = forms.zimage.snapshot() // remember the form across launches
        if scenarioPrompts == nil {
            settings.recordPromptUse(forms.zimage.prompt)
        }
        let jobs = PromptFanOut.jobs(prompt: forms.zimage.prompt, scenarioPrompts: scenarioPrompts, count: count) {
            ($0, forms.zimage.negativePrompt)
        }.map {
            forms.zimage.makeJob(
                count: $0.count,
                customModelRepo: forms.flux.effectiveCustomRepo,
                resolvedPrompt: ($0.positive, $0.negative),
                size: AspectDirective.size(
                    ratio: $0.ratio, width: forms.zimage.width, height: forms.zimage.height, constraints: .zimage
                )
            )
        }
        return queue(jobs, on: families.zimage)
    }

    /// Qwen-Image 2.1 has no negative prompt; an edit's references and size
    /// choice ride along on every job unchanged.
    private func generateQwen21(count: Int, scenarioPrompts: [String]?) -> PreviewState? {
        let hasReferences = !forms.qwen21.isEditMode || !forms.qwen21.editImagePaths.isEmpty
        guard forms.qwen21.canGenerate || (scenarioPrompts?.isEmpty == false && hasReferences) else { return nil }
        settings.lastModel = forms.flux.model == .custom ? .custom : .qwen21Turbo
        settings.lastQwen21 = forms.qwen21.snapshot()
        forms.qwen21.lowRam = settings.resolvedDefaults(for: .qwen21Turbo).lowRam
        forms.qwen21.routesToComfy = Qwen21RunnerSpec.routesToComfy(settings: settings)
        if scenarioPrompts == nil {
            settings.recordPromptUse(forms.qwen21.prompt)
        }
        let jobs = PromptFanOut.jobs(prompt: forms.qwen21.prompt, scenarioPrompts: scenarioPrompts, count: count) {
            ($0, "")
        }.map {
            forms.qwen21.makeJob(
                count: $0.count,
                customModelRepo: forms.flux.effectiveCustomRepo,
                resolvedPrompt: $0.positive,
                size: AspectDirective.size(
                    ratio: $0.ratio, width: forms.qwen21.width, height: forms.qwen21.height, constraints: .qwen21
                )
            )
        }
        return queue(jobs, on: families.qwen21)
    }

    private func queue<Spec>(_ jobs: [Spec.Job], on queue: FamilyQueue<Spec>) -> PreviewState? {
        let wasIdle = queues.enqueue(jobs, on: queue)
        return wasIdle ? jobs.first.map { Spec.preview($0) } : nil
    }
}

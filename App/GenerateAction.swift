import Foundation

/// One Generate press: checks the active family's form, remembers it in
/// settings for the next launch, and queues its jobs. Holds references only:
/// ``ContentView`` builds one from its state as needed.
struct GenerateAction {
    let settings: AppSettings
    let params: ParamsPanelState
    let ideogramParams: Ideogram4ParamsPanelState
    let krea2Params: Krea2ParamsPanelState
    let zimageParams: ZImageParamsPanelState
    let qwen21Params: Qwen21ParamsPanelState
    let queues: FamilyQueues

    /// The active family's prompt field, for ``PromptBatchSplitter``. Nil for
    /// Ideogram 4, whose caption is a structured document with no per-prompt path.
    private var batchablePromptField: String? {
        switch params.modelFamily {
        case .flux: params.prompt
        case .krea2: krea2Params.prompt
        case .zimage: zimageParams.prompt
        case .qwen21: qwen21Params.prompt
        case .ideogram4, .seedvr2: nil
        }
    }

    /// Keeps the prompts typed but not yet generated with the current profile.
    /// Generating saves these too; this covers leaving the profile first.
    func saveContentDrafts() {
        settings.lastPrompt = params.prompt
        settings.lastLoras = params.loras
        settings.lastKrea2 = krea2Params.snapshot()
        settings.lastZImage = zimageParams.snapshot()
        settings.lastQwen21 = qwen21Params.snapshot()
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
                if params.modelFamily == .flux {
                    settings.lastPrompt = field
                }
                settings.recordPromptUse(field)
                return self(count: prompts.count, scenarioPrompts: prompts)
            }
        }

        // Remember the custom checkpoint and the family it loads as, so the
        // selection is intact on relaunch. Each family below sets `lastModel`;
        // these two are what make `.custom` mean something again.
        if params.model == .custom {
            settings.lastCustomModelRepo = params.customModelRepo
            settings.lastCustomBaseModel = params.customBaseModel
        }

        switch params.modelFamily {
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
        guard scenarioPrompts?.isEmpty == false || !params.prompt.trimmingCharacters(in: .whitespaces).isEmpty,
              !params.isEditMode || !params.editImagePaths.isEmpty else { return nil }
        if scenarioPrompts == nil {
            // Skip for scenario batches: N rolled prompts would swamp the history,
            // and each image's sidecar already records the prompt it used.
            settings.lastPrompt = params.prompt
            settings.recordPromptUse(params.prompt)
        }
        settings.lastWidth = params.width
        settings.lastHeight = params.height
        settings.lastLoras = params.loras
        settings.lastModel = params.model
        settings.lastQuantize = params.quantize
        // Low RAM lives in Settings -> Models; read it now so a toggle applies to
        // this run instead of only after a relaunch.
        params.applyMemoryDefaults(from: settings)
        let constraints: DimensionConstraints = params.model.isFlux ? .flux2 : .legacy
        let jobs = PromptFanOut.jobs(prompt: params.prompt, scenarioPrompts: scenarioPrompts, count: count) {
            params.templatedPrompts(templates: settings.activeTemplates, overriding: $0)
        }.map {
            params.makeJob(
                count: $0.count,
                resolvedPrompt: ($0.positive, $0.negative),
                size: AspectDirective.size(ratio: $0.ratio, width: params.width, height: params.height, constraints: constraints)
            )
        }
        return queue(jobs, in: queues.flux, on: queues.fluxRunner, preview: PreviewState.activeJob)
    }

    private func generateIdeogram4(count: Int) -> PreviewState? {
        guard ideogramParams.isReadyToGenerate(settings: settings) else { return nil }
        // Remember the picker selection across sessions — `custom` must survive
        // as itself, not be flattened to the family it happens to load as.
        settings.lastModel = params.model == .custom ? .custom : .ideogram4
        settings.lastIdeogramPreset = ideogramParams.preset
        settings.lastIdeogramWidth = ideogramParams.width
        settings.lastIdeogramHeight = ideogramParams.height
        settings.lastIdeogramQuantize = ideogramParams.quantize
        settings.lastIdeogramCaption = ideogramParams.caption
        settings.lastIdeogramPlainPrompt = ideogramParams.plainPrompt
        settings.lastIdeogramUsePlainPrompt = ideogramParams.usePlainPrompt
        settings.lastIdeogramSeed = ideogramParams.seed
        // Low-RAM and strict-validation live in Settings → Models → Ideogram;
        // pull the current values so live edits apply to this run.
        ideogramParams.lowRam = settings.ideogram4LowRam
        ideogramParams.strictValidation = settings.ideogram4StrictValidation
        let job = ideogramParams.makeJob(count: count, customModelRepo: params.effectiveCustomRepo)
        return queue([job], in: queues.ideogram4, on: queues.ideogram4Runner, preview: PreviewState.activeIdeogram4Job)
    }

    private func generateKrea2(count: Int, scenarioPrompts: [String]?) -> PreviewState? {
        guard krea2Params.isReadyToGenerate(settings: settings) || scenarioPrompts?.isEmpty == false else { return nil }
        // Remember the picker selection across sessions — `custom` must survive as
        // itself, not be flattened to the family it happens to load as.
        settings.lastModel = params.model == .custom ? .custom : .krea2
        settings.lastKrea2 = krea2Params.snapshot() // remember the form across launches
        // Low-RAM lives in Settings → Models → Krea 2; pull it so live edits apply to this run.
        krea2Params.lowRam = settings.resolvedDefaults(for: .krea2).lowRam
        if scenarioPrompts == nil {
            settings.recordPromptUse(krea2Params.prompt)
        }
        let jobs = PromptFanOut.jobs(prompt: krea2Params.prompt, scenarioPrompts: scenarioPrompts, count: count) {
            ($0, krea2Params.negativePrompt)
        }.map {
            krea2Params.makeJob(
                count: $0.count,
                customModelRepo: params.effectiveCustomRepo,
                resolvedPrompt: ($0.positive, $0.negative),
                size: AspectDirective.size(
                    ratio: $0.ratio, width: krea2Params.width, height: krea2Params.height, constraints: .krea2
                )
            )
        }
        return queue(jobs, in: queues.krea2, on: queues.krea2Runner, preview: PreviewState.activeKrea2Job)
    }

    private func generateZImage(count: Int, scenarioPrompts: [String]?) -> PreviewState? {
        guard zimageParams.isReadyToGenerate(settings: settings) || scenarioPrompts?.isEmpty == false else { return nil }
        // Remember the picker selection across sessions — `custom` must survive as
        // itself, not be flattened to the variant it happens to load as.
        settings.lastModel = params.model == .custom ? .custom : zimageParams.variant
        settings.lastZImage = zimageParams.snapshot() // remember the form across launches
        if scenarioPrompts == nil {
            settings.recordPromptUse(zimageParams.prompt)
        }
        let jobs = PromptFanOut.jobs(prompt: zimageParams.prompt, scenarioPrompts: scenarioPrompts, count: count) {
            ($0, zimageParams.negativePrompt)
        }.map {
            zimageParams.makeJob(
                count: $0.count,
                customModelRepo: params.effectiveCustomRepo,
                resolvedPrompt: ($0.positive, $0.negative),
                size: AspectDirective.size(
                    ratio: $0.ratio, width: zimageParams.width, height: zimageParams.height, constraints: .zimage
                )
            )
        }
        return queue(jobs, in: queues.zimage, on: queues.zimageRunner, preview: PreviewState.activeZImageJob)
    }

    /// Qwen-Image 2.1 has no negative prompt; an edit's references and size
    /// choice ride along on every job unchanged.
    private func generateQwen21(count: Int, scenarioPrompts: [String]?) -> PreviewState? {
        let hasReferences = !qwen21Params.isEditMode || !qwen21Params.editImagePaths.isEmpty
        guard qwen21Params.canGenerate || (scenarioPrompts?.isEmpty == false && hasReferences) else { return nil }
        settings.lastModel = params.model == .custom ? .custom : .qwen21Turbo
        settings.lastQwen21 = qwen21Params.snapshot()
        qwen21Params.lowRam = settings.resolvedDefaults(for: .qwen21Turbo).lowRam
        qwen21Params.routesToComfy = Qwen21RunnerSpec.routesToComfy(settings: settings)
        if scenarioPrompts == nil {
            settings.recordPromptUse(qwen21Params.prompt)
        }
        let jobs = PromptFanOut.jobs(prompt: qwen21Params.prompt, scenarioPrompts: scenarioPrompts, count: count) {
            ($0, "")
        }.map {
            qwen21Params.makeJob(
                count: $0.count,
                customModelRepo: params.effectiveCustomRepo,
                resolvedPrompt: $0.positive,
                size: AspectDirective.size(
                    ratio: $0.ratio, width: qwen21Params.width, height: qwen21Params.height, constraints: .qwen21
                )
            )
        }
        return queue(jobs, in: queues.qwen21, on: queues.qwen21Runner, preview: PreviewState.activeQwen21Job)
    }

    private func queue<Spec: JobRunnerSpec>(
        _ jobs: [Spec.Job],
        in store: Spec.Store,
        on runner: JobRunner<Spec>,
        preview: (Spec.Job) -> PreviewState
    ) -> PreviewState? where Spec.Job: QueueListedJob, Spec.Store: ProfileScopedJobStore,
        Spec.Store.PersistedJob == Spec.Job {
        let wasIdle = queues.enqueue(jobs, in: store, on: runner)
        return wasIdle ? jobs.first.map(preview) : nil
    }
}

/// How one Generate press becomes jobs, for every family with a prompt field
/// (Flux, Krea 2, Z-Image, Qwen-Image 2.1):
///
/// - A scenario batch: one single-image job per rolled prompt. Any {a|b} group
///   the LLM emitted collapses to one sample; the batch's variety comes from
///   re-rolling, not from fanning out again.
/// - A field with wildcards: one job per option of the largest {a|b} group, at
///   most ``maxVariants``. A batch count above 1 sets the job count instead.
/// - Otherwise one job, of the batch count.
///
/// Each prompt's `@aspect` directive is stripped and returned as the job's ratio.
enum PromptFanOut {
    /// One job to queue. The family turns `ratio` into a size and builds its job.
    struct Job: Equatable {
        var positive: String
        var negative: String
        /// From the prompt's `@aspect` directive; nil keeps the form's size.
        var ratio: Double?
        /// Images in the job; above 1 only for a job that did not fan out.
        var count: Int
    }

    static let maxVariants = 10

    /// `resolve` turns a directive-free prompt into what the job runs: the
    /// prompt with the family's negative field, or Flux's templates applied.
    static func jobs(
        prompt: String,
        scenarioPrompts: [String]?,
        count: Int,
        resolve: (String) -> (positive: String, negative: String)
    ) -> [Job] {
        var rng = SystemRandomNumberGenerator()
        return jobs(prompt: prompt, scenarioPrompts: scenarioPrompts, count: count, resolve: resolve, using: &rng)
    }

    static func jobs(
        prompt: String,
        scenarioPrompts: [String]?,
        count: Int,
        resolve: (String) -> (positive: String, negative: String),
        using rng: inout some RandomNumberGenerator
    ) -> [Job] {
        if let scenarioPrompts, !scenarioPrompts.isEmpty {
            return scenarioPrompts.map {
                let directive = AspectDirective.extract(from: $0)
                let pair = collapse(resolve(directive.prompt), using: &rng)
                return Job(positive: pair.positive, negative: pair.negative, ratio: directive.ratio, count: 1)
            }
        }
        let directive = AspectDirective.extract(from: prompt)
        let pair = resolve(directive.prompt)
        let variants = min(WildcardExpander.variantCount(pair.positive), maxVariants)
        guard variants > 1 else {
            let single = collapse(pair, using: &rng)
            return [Job(positive: single.positive, negative: single.negative, ratio: directive.ratio, count: count)]
        }
        let jobCount = count > 1 ? count : variants
        let positives = WildcardExpander.expandVariants(pair.positive, count: jobCount, using: &rng)
        let negatives = WildcardExpander.expandVariants(pair.negative, count: jobCount, using: &rng)
        return zip(positives, negatives).map { Job(positive: $0, negative: $1, ratio: directive.ratio, count: 1) }
    }

    /// One sample of each {a|b} group in a prompt that does not fan out.
    private static func collapse(
        _ pair: (positive: String, negative: String),
        using rng: inout some RandomNumberGenerator
    ) -> (positive: String, negative: String) {
        (
            WildcardExpander.expandVariants(pair.positive, count: 1, using: &rng).first ?? pair.positive,
            WildcardExpander.expandVariants(pair.negative, count: 1, using: &rng).first ?? pair.negative
        )
    }
}

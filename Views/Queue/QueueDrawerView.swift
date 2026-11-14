// swiftlint:disable file_length
import SwiftUI

struct QueueDrawerView: View {
    @Environment(JobStore.self) private var store
    @Environment(FluxJobRunner.self) private var runner
    @Environment(AppSettings.self) private var settings
    @Environment(GenerationCoordinator.self) private var coordinator
    @Environment(TimingStore.self) private var timing

    @Binding var selectedJob: FluxJob?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.jobs.isEmpty {
                emptyState
            } else {
                jobList
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Queue")
                .font(.headline)
            Spacer()
            if store.jobs.contains(where: \.status.isTerminal) {
                PurgeFinishedButton { store.purgeTerminal() }
            }
            if store.isRunning {
                Button(runner.isStopping ? "Force Stop" : "Stop") { runner.cancel() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.red)
                    .focusable(false)
                    .help(runner.isStopping
                        ? "Stop immediately without waiting for the current step; the warm model is unloaded"
                        : "Stop the current job; remaining pending jobs continue")

                Button(runner.isStopping ? "Force Stop All" : "Stop All") {
                    runner.cancel()
                    store.cancelAllPending()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .focusable(false)
                .help(runner.isStopping
                    ? "Stop immediately without waiting for the current step, and cancel all pending jobs"
                    : "Stop the current job and cancel all pending jobs")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var jobList: some View {
        List(selection: Binding(
            get: { selectedJob?.id },
            set: { id in selectedJob = store.jobs.first { $0.id == id } }
        )) {
            ForEach(store.jobs) { job in
                QueueJobRow(
                    job: job,
                    onRestart: isRestartable(job) ? { restart(job) } : nil,
                    onCancel: isCancellable(job) ? { cancelJob(job) } : nil
                )
                .tag(job.id)
            }
        }
        .listStyle(.sidebar)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("No jobs")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private func isRestartable(_ job: FluxJob) -> Bool {
        switch job.status {
        case .failed, .cancelled: true
        default: false
        }
    }

    private func isCancellable(_ job: FluxJob) -> Bool {
        switch job.status {
        case .pending, .running: true
        default: false
        }
    }

    private func restart(_ job: FluxJob) {
        store.restart(job)
        runner.runNext(in: store, settings: settings, coordinator: coordinator, timing: timing)
    }

    private func cancelJob(_ job: FluxJob) {
        if case .running = job.status {
            runner.cancel()
        } else {
            store.cancelJob(job)
        }
    }
}

// MARK: - Ideogram4QueueDrawerView

/// Queue drawer for the Ideogram 4 pipeline. Mirrors ``QueueDrawerView`` but is
/// backed by ``Ideogram4JobStore`` / ``Ideogram4JobRunner`` so single-shot and
/// batch Ideogram jobs show up while that pipeline is the active model family.
struct Ideogram4QueueDrawerView: View {
    @Environment(Ideogram4JobStore.self) private var store
    @Environment(Ideogram4JobRunner.self) private var runner
    @Environment(AppSettings.self) private var settings
    @Environment(GenerationCoordinator.self) private var coordinator
    @Environment(TimingStore.self) private var timing

    @Binding var selectedJob: Ideogram4Job?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.jobs.isEmpty {
                emptyState
            } else {
                jobList
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Queue")
                .font(.headline)
            Spacer()
            if store.jobs.contains(where: \.status.isTerminal) {
                PurgeFinishedButton { store.purgeTerminal() }
            }
            if store.isRunning {
                Button(runner.isStopping ? "Force Stop" : "Stop") { runner.cancel() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.red)
                    .focusable(false)
                    .help(runner.isStopping
                        ? "Stop immediately without waiting for the current step; the warm model is unloaded"
                        : "Stop the current job; remaining pending jobs continue")

                Button(runner.isStopping ? "Force Stop All" : "Stop All") {
                    runner.cancel()
                    store.cancelAllPending()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .focusable(false)
                .help(runner.isStopping
                    ? "Stop immediately without waiting for the current step, and cancel all pending jobs"
                    : "Stop the current job and cancel all pending jobs")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var jobList: some View {
        List(selection: Binding(
            get: { selectedJob?.id },
            set: { id in selectedJob = store.jobs.first { $0.id == id } }
        )) {
            ForEach(store.jobs) { job in
                Ideogram4QueueJobRow(
                    job: job,
                    onRestart: isRestartable(job) ? { restart(job) } : nil,
                    onCancel: isCancellable(job) ? { cancelJob(job) } : nil
                )
                .tag(job.id)
            }
        }
        .listStyle(.sidebar)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("No jobs")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private func isRestartable(_ job: Ideogram4Job) -> Bool {
        switch job.status {
        case .failed, .cancelled: true
        default: false
        }
    }

    private func isCancellable(_ job: Ideogram4Job) -> Bool {
        switch job.status {
        case .pending, .running: true
        default: false
        }
    }

    private func restart(_ job: Ideogram4Job) {
        store.restart(job)
        runner.runNext(in: store, settings: settings, coordinator: coordinator, timing: timing)
    }

    private func cancelJob(_ job: Ideogram4Job) {
        if case .running = job.status {
            runner.cancel()
        } else {
            store.cancelJob(job)
        }
    }
}

// MARK: - QueueJobRow

private struct QueueJobRow: View {
    let job: FluxJob
    var onRestart: (() -> Void)?
    var onCancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(job.prompt.isEmpty ? "(empty prompt)" : job.prompt)
                    .font(.caption)
                    .lineLimit(2)
                Text(job.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                // Compact: queue rows are dense and cancel/restart sit side by side.
                .buttonStyle(.iconButtonCompact)
                .focusable(false)
                .help("Cancel this job")
            }
            if let onRestart {
                Button(action: onRestart) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.iconButtonCompact)
                .focusable(false)
                .help("Re-queue this job")
            }
        }
        .padding(.vertical, 2)
    }

    private var statusIcon: some View {
        JobStatusIcon(status: job.status)
    }
}

// MARK: - Ideogram4QueueJobRow

private struct Ideogram4QueueJobRow: View {
    let job: Ideogram4Job
    var onRestart: (() -> Void)?
    var onCancel: (() -> Void)?

    /// Ideogram jobs have no single `prompt` field — surface the plain prompt or
    /// the structured caption's high-level description, whichever is in use.
    private var promptText: String {
        let text = job.usePlainPrompt ? job.plainPrompt : job.caption.highLevelDescription
        return text.isEmpty ? "(empty prompt)" : text
    }

    var body: some View {
        HStack(spacing: 8) {
            JobStatusIcon(status: job.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(promptText)
                    .font(.caption)
                    .lineLimit(2)
                Text(job.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                // Compact: queue rows are dense and cancel/restart sit side by side.
                .buttonStyle(.iconButtonCompact)
                .focusable(false)
                .help("Cancel this job")
            }
            if let onRestart {
                Button(action: onRestart) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.iconButtonCompact)
                .focusable(false)
                .help("Re-queue this job")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - FamilyQueueDrawerView

/// Queue drawer for a family whose jobs are ``QueueListedJob``s (Krea 2,
/// Qwen-Image 2.1), driven by that family's runner spec.
struct FamilyQueueDrawerView<Spec: JobRunnerSpec>: View
    where Spec.Job: QueueListedJob, Spec.Store: ProfileScopedJobStore & Observable, Spec.Store.PersistedJob == Spec.Job {
    @Environment(Spec.Store.self) private var store
    @Environment(JobRunner<Spec>.self) private var runner
    @Environment(AppSettings.self) private var settings
    @Environment(GenerationCoordinator.self) private var coordinator
    @Environment(TimingStore.self) private var timing

    @Binding var selectedJob: Spec.Job?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.jobs.isEmpty {
                emptyState
            } else {
                jobList
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Queue")
                .font(.headline)
            Spacer()
            if store.jobs.contains(where: \.status.isTerminal) {
                PurgeFinishedButton { store.purgeTerminal() }
            }
            if store.isRunning {
                Button(runner.isStopping ? "Force Stop" : "Stop") { runner.cancel() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.red)
                    .focusable(false)
                    .help(runner.isStopping
                        ? "Stop immediately without waiting for the current step; the warm model is unloaded"
                        : "Stop the current job; remaining pending jobs continue")

                Button(runner.isStopping ? "Force Stop All" : "Stop All") {
                    runner.cancel()
                    store.cancelAllPending()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .focusable(false)
                .help(runner.isStopping
                    ? "Stop immediately without waiting for the current step, and cancel all pending jobs"
                    : "Stop the current job and cancel all pending jobs")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var jobList: some View {
        List(selection: Binding(
            get: { selectedJob?.id },
            set: { id in selectedJob = store.jobs.first { $0.id == id } }
        )) {
            ForEach(store.jobs) { job in
                FamilyQueueJobRow(
                    job: job,
                    onRestart: isRestartable(job) ? { restart(job) } : nil,
                    onCancel: isCancellable(job) ? { cancelJob(job) } : nil
                )
                .tag(job.id)
            }
        }
        .listStyle(.sidebar)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("No jobs")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private func isRestartable(_ job: Spec.Job) -> Bool {
        switch job.status {
        case .failed, .cancelled: true
        default: false
        }
    }

    private func isCancellable(_ job: Spec.Job) -> Bool {
        switch job.status {
        case .pending, .running: true
        default: false
        }
    }

    private func restart(_ job: Spec.Job) {
        store.restart(job)
        runner.runNext(in: store, settings: settings, coordinator: coordinator, timing: timing)
    }

    private func cancelJob(_ job: Spec.Job) {
        if case .running = job.status {
            runner.cancel()
        } else {
            store.cancelJob(job)
        }
    }
}

// MARK: - FamilyQueueJobRow

private struct FamilyQueueJobRow<Job: QueueListedJob>: View {
    let job: Job
    var onRestart: (() -> Void)?
    var onCancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            JobStatusIcon(status: job.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.prompt.isEmpty ? "(empty prompt)" : job.prompt)
                    .font(.caption)
                    .lineLimit(2)
                Text(job.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                // Compact: queue rows are dense and cancel/restart sit side by side.
                .buttonStyle(.iconButtonCompact)
                .focusable(false)
                .help("Cancel this job")
            }
            if let onRestart {
                Button(action: onRestart) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.iconButtonCompact)
                .focusable(false)
                .help("Re-queue this job")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - ZImageQueueDrawerView

struct ZImageQueueDrawerView: View {
    @Environment(ZImageJobStore.self) private var store
    @Environment(ZImageJobRunner.self) private var runner
    @Environment(AppSettings.self) private var settings
    @Environment(GenerationCoordinator.self) private var coordinator
    @Environment(TimingStore.self) private var timing

    @Binding var selectedJob: ZImageJob?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.jobs.isEmpty {
                emptyState
            } else {
                jobList
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Queue")
                .font(.headline)
            Spacer()
            if store.jobs.contains(where: \.status.isTerminal) {
                PurgeFinishedButton { store.purgeTerminal() }
            }
            if store.isRunning {
                Button(runner.isStopping ? "Force Stop" : "Stop") { runner.cancel() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.red)
                    .focusable(false)
                    .help(runner.isStopping
                        ? "Stop immediately without waiting for the current step; the warm model is unloaded"
                        : "Stop the current job; remaining pending jobs continue")

                Button(runner.isStopping ? "Force Stop All" : "Stop All") {
                    runner.cancel()
                    store.cancelAllPending()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .focusable(false)
                .help(runner.isStopping
                    ? "Stop immediately without waiting for the current step, and cancel all pending jobs"
                    : "Stop the current job and cancel all pending jobs")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var jobList: some View {
        List(selection: Binding(
            get: { selectedJob?.id },
            set: { id in selectedJob = store.jobs.first { $0.id == id } }
        )) {
            ForEach(store.jobs) { job in
                ZImageQueueJobRow(
                    job: job,
                    onRestart: isRestartable(job) ? { restart(job) } : nil,
                    onCancel: isCancellable(job) ? { cancelJob(job) } : nil
                )
                .tag(job.id)
            }
        }
        .listStyle(.sidebar)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("No jobs")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private func isRestartable(_ job: ZImageJob) -> Bool {
        switch job.status {
        case .failed, .cancelled: true
        default: false
        }
    }

    private func isCancellable(_ job: ZImageJob) -> Bool {
        switch job.status {
        case .pending, .running: true
        default: false
        }
    }

    private func restart(_ job: ZImageJob) {
        store.restart(job)
        runner.runNext(in: store, settings: settings, coordinator: coordinator, timing: timing)
    }

    private func cancelJob(_ job: ZImageJob) {
        if case .running = job.status {
            runner.cancel()
        } else {
            store.cancelJob(job)
        }
    }
}

// MARK: - ZImageQueueJobRow

private struct ZImageQueueJobRow: View {
    let job: ZImageJob
    var onRestart: (() -> Void)?
    var onCancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            JobStatusIcon(status: job.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.prompt.isEmpty ? "(empty prompt)" : job.prompt)
                    .font(.caption)
                    .lineLimit(2)
                Text(job.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                // Compact: queue rows are dense and cancel/restart sit side by side.
                .buttonStyle(.iconButtonCompact)
                .focusable(false)
                .help("Cancel this job")
            }
            if let onRestart {
                Button(action: onRestart) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.iconButtonCompact)
                .focusable(false)
                .help("Re-queue this job")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - SeedVR2QueueDrawerView

/// Queue drawer for the SeedVR2 upscaler. Mirrors ``FamilyQueueDrawerView`` but is
/// backed by ``SeedVR2JobStore`` / ``SeedVR2JobRunner``. SeedVR2 is not a
/// picker-selected family — upscales are an action applied to an existing image —
/// so the queue sheet surfaces this drawer whenever an upscale is running or the
/// preview is showing one, rather than keying on the active model family.
struct SeedVR2QueueDrawerView: View {
    @Environment(SeedVR2JobStore.self) private var store
    @Environment(SeedVR2JobRunner.self) private var runner
    @Environment(AppSettings.self) private var settings
    @Environment(GenerationCoordinator.self) private var coordinator
    @Environment(TimingStore.self) private var timing

    @Binding var selectedJob: SeedVR2Job?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.jobs.isEmpty {
                emptyState
            } else {
                jobList
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Queue")
                .font(.headline)
            Spacer()
            if store.jobs.contains(where: \.status.isTerminal) {
                PurgeFinishedButton { store.purgeTerminal() }
            }
            if store.isRunning {
                Button(runner.isStopping ? "Force Stop" : "Stop") { runner.cancel() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.red)
                    .focusable(false)
                    .help(runner.isStopping
                        ? "Stop immediately without waiting for the current step; the warm model is unloaded"
                        : "Stop the current job; remaining pending jobs continue")

                Button(runner.isStopping ? "Force Stop All" : "Stop All") {
                    runner.cancel()
                    store.cancelAllPending()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .focusable(false)
                .help(runner.isStopping
                    ? "Stop immediately without waiting for the current step, and cancel all pending jobs"
                    : "Stop the current job and cancel all pending jobs")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var jobList: some View {
        List(selection: Binding(
            get: { selectedJob?.id },
            set: { id in selectedJob = store.jobs.first { $0.id == id } }
        )) {
            ForEach(store.jobs) { job in
                SeedVR2QueueJobRow(
                    job: job,
                    onRestart: isRestartable(job) ? { restart(job) } : nil,
                    onCancel: isCancellable(job) ? { cancelJob(job) } : nil
                )
                .tag(job.id)
            }
        }
        .listStyle(.sidebar)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("No jobs")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private func isRestartable(_ job: SeedVR2Job) -> Bool {
        switch job.status {
        case .failed, .cancelled: true
        default: false
        }
    }

    private func isCancellable(_ job: SeedVR2Job) -> Bool {
        switch job.status {
        case .pending, .running: true
        default: false
        }
    }

    private func restart(_ job: SeedVR2Job) {
        store.restart(job)
        runner.runNext(in: store, settings: settings, coordinator: coordinator, timing: timing)
    }

    private func cancelJob(_ job: SeedVR2Job) {
        if case .running = job.status {
            runner.cancel()
        } else {
            store.cancelJob(job)
        }
    }
}

// MARK: - SeedVR2QueueJobRow

private struct SeedVR2QueueJobRow: View {
    let job: SeedVR2Job
    var onRestart: (() -> Void)?
    var onCancel: (() -> Void)?

    /// SeedVR2 jobs have no prompt — surface the source image's filename so the row
    /// is identifiable, with the upscale settings on the secondary line.
    private var sourceName: String {
        let name = (job.sourcePath as NSString).lastPathComponent
        return name.isEmpty ? "(upscale)" : name
    }

    var body: some View {
        HStack(spacing: 8) {
            JobStatusIcon(status: job.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(sourceName)
                    .font(.caption)
                    .lineLimit(2)
                Text(job.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                // Compact: queue rows are dense and cancel/restart sit side by side.
                .buttonStyle(.iconButtonCompact)
                .focusable(false)
                .help("Cancel this job")
            }
            if let onRestart {
                Button(action: onRestart) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.iconButtonCompact)
                .focusable(false)
                .help("Re-queue this job")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - JobStatusIcon

/// Shared status glyph for Flux, Ideogram, Krea 2, and SeedVR2 queue rows.
/// Clears finished jobs from a queue drawer, after a confirmation: their logs go with them.
private struct PurgeFinishedButton: View {
    let purge: () -> Void
    @State private var confirming = false

    var body: some View {
        Button {
            confirming = true
        } label: {
            Image(systemName: "trash")
                .font(.caption)
        }
        .buttonStyle(.iconButton)
        .foregroundStyle(.secondary)
        .focusable(false)
        .help("Remove all completed, failed, and cancelled jobs")
        .confirmationDialog("Remove finished jobs?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Remove", role: .destructive, action: purge)
        } message: {
            Text("Completed, failed, and cancelled jobs leave the queue. Saved images stay in the gallery.")
        }
    }
}

private struct JobStatusIcon: View {
    let status: JobStatus

    var body: some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(.tertiary)

        case .running:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)

        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)

        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)

        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

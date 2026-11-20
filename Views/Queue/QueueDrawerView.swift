import SwiftUI

// MARK: - FamilyQueueDrawerView

/// The queue drawer for any family, driven by that family's runner spec.
struct FamilyQueueDrawerView<Spec: JobRunnerSpec>: View
    where Spec.Job: QueueListedJob, Spec.Store: ProfileScopedJobStore & Observable,
    Spec.Store.PersistedJob == Spec.Job {
    @Environment(Spec.Store.self) private var store
    @Environment(JobRunner<Spec>.self) private var runner
    @Environment(AppSettings.self) private var settings
    @Environment(GenerationCoordinator.self) private var coordinator
    @Environment(TimingStore.self) private var timing

    @Binding var selectedJob: Spec.Job?
    /// The row menu's Duplicate. Nil for SeedVR2, whose upscales cannot be copied.
    private let duplicate: (@MainActor (Spec.Store, Spec.Job) -> Void)?

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
                .queueRowActions(job, in: store, duplicate: duplicate.map { fn in { fn(store, job) } }, start: startNext)
            }
            .onMove { store.movePending(fromOffsets: $0, toOffset: $1) }
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

    /// The drawer for a generating family: its rows can be duplicated.
    init(selectedJob: Binding<Spec.Job?>) where Spec.Job: SeedSplittableJob {
        _selectedJob = selectedJob
        duplicate = { store, job in store.duplicate(job) }
    }

    /// The drawer for SeedVR2, whose rows have no Duplicate. A separate label,
    /// not an overload: a family that lost its `SeedSplittableJob` conformance
    /// would otherwise build here and lose Duplicate silently.
    init(selectedJobWithoutDuplicate selectedJob: Binding<Spec.Job?>) {
        _selectedJob = selectedJob
        duplicate = nil
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
        startNext()
    }

    private func startNext() {
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
                Text(job.queueRowTitle)
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
                .accessibilityLabel("Cancel job")
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
                .accessibilityLabel("Re-queue job")
            }
        }
        .padding(.vertical, 2)
        .failureHelp(job.status)
    }
}

// MARK: - Header and status pieces

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
        .accessibilityLabel("Remove finished jobs")
        .confirmationDialog("Remove finished jobs?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Remove", role: .destructive, action: purge)
        } message: {
            Text("Completed, failed, and cancelled jobs leave the queue. Saved images stay in the gallery.")
        }
    }
}

/// A queue row's status glyph.
private struct JobStatusIcon: View {
    let status: JobStatus

    var body: some View {
        // What the glyph means, for VoiceOver; a failure reads its error too.
        icon.accessibilityLabel(status.label)
    }

    @ViewBuilder private var icon: some View {
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

private extension View {
    /// A failed job's row shows its error as a tooltip; other rows show none.
    @ViewBuilder
    func failureHelp(_ status: JobStatus) -> some View {
        if case let .failed(message) = status {
            help(message)
        } else {
            self
        }
    }
}

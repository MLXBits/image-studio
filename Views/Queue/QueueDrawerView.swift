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
                Button {
                    store.purgeTerminal()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .focusable(false)
                .help("Remove all completed, failed, and cancelled jobs")
            }
            if store.isRunning {
                Button("Stop") { runner.cancel() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.red)
                    .focusable(false)
                    .help("Stop the current job; remaining pending jobs continue")

                Button("Stop All") {
                    runner.cancel()
                    store.cancelAllPending()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .focusable(false)
                .help("Stop the current job and cancel all pending jobs")
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
                Button {
                    store.purgeTerminal()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .focusable(false)
                .help("Remove all completed, failed, and cancelled jobs")
            }
            if store.isRunning {
                Button("Stop") { runner.cancel() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.red)
                    .focusable(false)
                    .help("Stop the current job; remaining pending jobs continue")

                Button("Stop All") {
                    runner.cancel()
                    store.cancelAllPending()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .focusable(false)
                .help("Stop the current job and cancel all pending jobs")
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
                .buttonStyle(.plain)
                .focusable(false)
                .help("Cancel this job")
            }
            if let onRestart {
                Button(action: onRestart) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
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
                .buttonStyle(.plain)
                .focusable(false)
                .help("Cancel this job")
            }
            if let onRestart {
                Button(action: onRestart) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Re-queue this job")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Krea2QueueDrawerView

struct Krea2QueueDrawerView: View {
    @Environment(Krea2JobStore.self) private var store
    @Environment(Krea2JobRunner.self) private var runner
    @Environment(AppSettings.self) private var settings
    @Environment(GenerationCoordinator.self) private var coordinator
    @Environment(TimingStore.self) private var timing

    @Binding var selectedJob: Krea2Job?

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
                Button {
                    store.purgeTerminal()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .focusable(false)
                .help("Remove all completed, failed, and cancelled jobs")
            }
            if store.isRunning {
                Button("Stop") { runner.cancel() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.red)
                    .focusable(false)
                    .help("Stop the current job; remaining pending jobs continue")

                Button("Stop All") {
                    runner.cancel()
                    store.cancelAllPending()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .focusable(false)
                .help("Stop the current job and cancel all pending jobs")
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
                Krea2QueueJobRow(
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

    private func isRestartable(_ job: Krea2Job) -> Bool {
        switch job.status {
        case .failed, .cancelled: true
        default: false
        }
    }

    private func isCancellable(_ job: Krea2Job) -> Bool {
        switch job.status {
        case .pending, .running: true
        default: false
        }
    }

    private func restart(_ job: Krea2Job) {
        store.restart(job)
        runner.runNext(in: store, settings: settings, coordinator: coordinator, timing: timing)
    }

    private func cancelJob(_ job: Krea2Job) {
        if case .running = job.status {
            runner.cancel()
        } else {
            store.cancelJob(job)
        }
    }
}

// MARK: - Krea2QueueJobRow

private struct Krea2QueueJobRow: View {
    let job: Krea2Job
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
                .buttonStyle(.plain)
                .focusable(false)
                .help("Cancel this job")
            }
            if let onRestart {
                Button(action: onRestart) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Re-queue this job")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - JobStatusIcon

/// Shared status glyph for Flux, Ideogram, and Krea 2 queue rows.
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

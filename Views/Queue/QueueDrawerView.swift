import SwiftUI

struct QueueDrawerView: View {
    @Environment(JobStore.self) private var store
    @Environment(FluxJobRunner.self) private var runner
    @Environment(AppSettings.self) private var settings

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
            if store.jobs.contains(where: { $0.status.isTerminal }) {
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
        case .failed, .cancelled: return true
        default: return false
        }
    }

    private func isCancellable(_ job: FluxJob) -> Bool {
        switch job.status {
        case .pending, .running: return true
        default: return false
        }
    }

    private func restart(_ job: FluxJob) {
        store.restart(job)
        runner.runNext(in: store, settings: settings)
    }

    private func cancelJob(_ job: FluxJob) {
        if case .running = job.status {
            runner.cancel()
        } else {
            store.cancelJob(job)
        }
    }
}

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

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
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

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
            if store.isRunning {
                Button("Stop") { runner.cancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(.red)
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
                QueueJobRow(job: job)
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
}

private struct QueueJobRow: View {
    let job: FluxJob

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

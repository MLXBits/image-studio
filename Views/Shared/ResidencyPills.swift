import SwiftUI

/// The header's trailing cluster: what each *external* inference host holds in memory.
/// ComfyUI and LM Studio are the hosts this app can reach; each pill is hidden until its
/// server is configured and reachable, so an unconfigured box costs nothing visually. The
/// local mflux driver's warm model is the model button's halo and eject button instead.
/// Both pills share one shape: an icon, a label (model name / size), and — only when
/// something is resident — an eject button.
struct ResidencyPills: View {
    /// The main window's model runs on ComfyUI: the ComfyUI pill shows only then.
    let runsOnComfy: Bool

    var body: some View {
        ComfyResidencyPill(runsOnComfy: runsOnComfy)
        LMStudioResidencyPill()
    }
}

// MARK: - Pills

/// ComfyUI residency: "Resident · ~X GB" when VRAM is meaningfully below the idle
/// baseline, or just "ComfyUI" (no size) while the server is reachable but the
/// baseline hasn't locked yet. Eject fires `POST /free` — ComfyUI's only eject is
/// a global unload of everything resident. Shown only while the selected model
/// runs on ComfyUI (``AppSettings/runsOnComfy(_:)``), so a local model's button has
/// the header to itself; the check also hides a reachable report from a poll that
/// was in flight when routing changed.
private struct ComfyResidencyPill: View {
    @Environment(BackendModelStore.self) private var backendModels

    let runsOnComfy: Bool

    var body: some View {
        if runsOnComfy, backendModels.comfy.reachable {
            ResidencyPill(systemImage: "server.rack") {
                VStack(alignment: .leading, spacing: 0) {
                    Text("ComfyUI")
                        .font(.caption2)
                        .fontWeight(.medium)
                    if let gb = backendModels.comfyResidentGB {
                        PillDetail(String(format: "%.1f GB resident", gb))
                    } else if backendModels.isComfyEjecting {
                        PillDetail("Freeing…")
                    }
                }
                // Eject only when we actually know something is resident — not mid-warmup, not offline.
                if backendModels.canEjectComfy {
                    EjectButton { backendModels.ejectComfy() }
                        // Don't let a user free ComfyUI's VRAM while our own local run is holding the GPU —
                        // the delta would be misattributed, and freeing mid-run could OOM the active job.
                        .disabled(backendModels.localRunInFlight)
                        .help(backendModels.localRunInFlight ? "Local run in progress" : "Unload all ComfyUI models")
                }
            }
        }
    }
}

/// LM Studio residency: each loaded model's short name and (first instance's)
/// context length. Eject unloads every resident instance (native
/// `/api/v1/models/unload` on LM Studio; `/models/unload` on llama.cpp). Hidden
/// when no remote LLM backend is configured, or when the server is reachable but
/// speaks no session API at all.
private struct LMStudioResidencyPill: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BackendModelStore.self) private var backendModels

    var body: some View {
        let entries = backendModels.lmLoadedEntries
        if settings.llmBackend == .remote && backendModels.lm.reachable, !entries.isEmpty {
            ResidencyPill(systemImage: "brain.profile") {
                VStack(alignment: .leading, spacing: 0) {
                    // One line per loaded model; a two-model box still fits the pill's width budget because we
                    // use the short key (last path component) and the context length, not full `org/model-quant`.
                    ForEach(Array(entries.enumerated()), id: \.element.model.key) { index, entry in
                        HStack(spacing: 3) {
                            Text(entry.model.shortKey)
                                .font(.caption2)
                                .fontWeight(index == 0 ? .medium : .regular)
                            if let ctx = entry.firstContextLength {
                                PillDetail("\(ctx / 1000)k")
                            }
                        }
                    }
                }
                EjectButton { backendModels.ejectAllLM() }
                    .help("Unload all models")
            }
        } else if settings.llmBackend == .remote && backendModels.lm.reachable && backendModels.isEjectingAll {
            // Models are mid-unload — show a "Freeing…" placeholder rather than the pill vanishing for one poll.
            ResidencyPill(systemImage: "brain.profile") {
                PillDetail("Freeing…")
            }
        }
    }
}

// MARK: - Pill pieces

/// A pill's chrome: the accent icon, then its content, in a quaternary capsule.
private struct ResidencyPill<Content: View>: View {
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            content
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.fill.quaternary, in: Capsule())
    }
}

/// A pill's secondary line: a size, a context length, or "Freeing…".
private struct PillDetail: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    init(_ text: String) {
        self.text = text
    }
}

/// A pill's eject button. Compact, so the target stays inside the pill.
private struct EjectButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "eject.fill")
                .font(.caption2)
        }
        .buttonStyle(.iconButtonCompact)
        .foregroundStyle(.secondary)
    }
}

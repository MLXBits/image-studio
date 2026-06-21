import SwiftUI

// MARK: - Reusable per-model form rows
//
// Shared building blocks for model-specific default forms. A "special" model —
// one whose option set diverges from the generic FLUX form — gets its own
// `ModelDefaultsView+<Model>Form.swift` that composes these rows, so adding a
// new model is a new file rather than another branch in a growing function.

/// A labelled toggle with a trailing info popover.
struct InfoToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    let infoTitle: String
    let infoDescription: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Toggle("", isOn: $isOn).labelsHidden()
                InfoButton(title: infoTitle, description: infoDescription)
            }
        }
    }
}

/// A labelled slider with a formatted value readout and trailing info popover.
struct InfoSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let infoTitle: String
    let infoDescription: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Slider(value: $value, in: range, step: step)
                    .frame(width: 120)
                Text(format(value))
                    .font(.caption).monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
                InfoButton(title: infoTitle, description: infoDescription)
            }
        }
    }
}

/// A "Model source" override field: repo/path text field + Browse button + info.
struct ModelSourceField: View {
    @Binding var repo: String
    let placeholder: String
    let infoTitle: String
    let infoDescription: String
    let browseAction: () -> Void

    var body: some View {
        LabeledContent("Model source") {
            HStack(spacing: 6) {
                TextField(placeholder, text: $repo)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit { repo = repo.trimmingCharacters(in: .whitespaces) }
                Button("Browse…", action: browseAction)
                    .controlSize(.small)
                InfoButton(title: infoTitle, description: infoDescription)
            }
        }
    }
}

// MARK: - Settings binding helpers
//
// `settings` comes from `@Environment`, which exposes no `$` projection. These
// build the explicit get/set bindings the forms need from a key path. Safe
// because `AppSettings` is a reference type, so the key path is writable.

extension ModelDefaultsView {
    /// A binding to a non-optional `AppSettings` property.
    func settingsBinding<T>(_ keyPath: ReferenceWritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { settings[keyPath: keyPath] = $0 }
        )
    }

    /// A binding to an optional `AppSettings` property, substituting `defaultValue` for `nil`.
    ///
    /// Use only when storing the default value is equivalent to storing `nil`. Fields
    /// whose `nil` carries distinct meaning (e.g. "use mflux default") need an explicit
    /// binding instead.
    func settingsBinding<T>(
        _ keyPath: ReferenceWritableKeyPath<AppSettings, T?>,
        default defaultValue: T
    ) -> Binding<T> {
        Binding(
            get: { settings[keyPath: keyPath] ?? defaultValue },
            set: { settings[keyPath: keyPath] = $0 }
        )
    }
}

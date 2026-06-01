import SwiftUI

/// A small ⓘ button that shows a popover with a title and description.
/// Use this instead of legacy tooltips for richer, touch-friendly help text.
struct InfoButton: View {
    let title: String
    let description: String
    var actionLabel: String = ""
    var action: (() -> Void)? = nil
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(title)")
        .accessibilityHint("Tap to learn more")
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .fontWeight(.semibold)
                    .font(.callout)
                Divider()
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let action, !actionLabel.isEmpty {
                    Divider()
                    Button {
                        action()
                        showing = false
                    } label: {
                        Label(actionLabel, systemImage: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(14)
            .frame(width: 260)
        }
    }
}

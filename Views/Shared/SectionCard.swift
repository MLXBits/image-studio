import SwiftUI

/// A titled, bordered container that visually delineates a section from its
/// parent without compounding background fills. Header uses the app's standard
/// caption/medium/secondary label idiom plus an optional `InfoButton` and an
/// optional trailing accessory (e.g. a count or "not set" hint).
struct SectionCard<Content: View, Trailing: View>: View {
    let title: String
    var info: String?
    var trailing: Trailing
    var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                if let info {
                    InfoButton(title: title, description: info)
                }
                Spacer()
                trailing
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }

    init(
        title: String,
        info: String? = nil,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.info = info
        self.trailing = trailing()
        self.content = content()
    }
}

extension SectionCard where Trailing == EmptyView {
    init(title: String, info: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, info: info, trailing: { EmptyView() }, content: content)
    }
}

/// A `SectionCard` whose body collapses behind a chevron disclosure header.
/// Bind `isExpanded` to `@AppStorage` to persist the open/closed state.
struct CollapsibleSectionCard<Content: View, Trailing: View>: View {
    let title: String
    var info: String?
    @Binding var isExpanded: Bool
    var trailing: Trailing
    var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                // Only the chevron + title toggle; InfoButton/trailing are siblings
                // so their own taps (e.g. the info popover) don't flip the section.
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .frame(width: 10)
                        Text(title)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let info {
                    InfoButton(title: title, description: info)
                }
                Spacer()
                trailing
            }

            if isExpanded {
                content
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }

    init(
        title: String,
        info: String? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.info = info
        _isExpanded = isExpanded
        self.trailing = trailing()
        self.content = content()
    }
}

extension CollapsibleSectionCard where Trailing == EmptyView {
    init(
        title: String,
        info: String? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            info: info,
            isExpanded: isExpanded,
            trailing: { EmptyView() },
            content: content
        )
    }
}

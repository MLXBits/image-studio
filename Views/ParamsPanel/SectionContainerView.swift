import SwiftUI

struct SectionContainerView<Content: View, Accessory: View>: View {
    let title: String?
    let info: String?
    @ViewBuilder let content: Content
    @ViewBuilder let accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    if let info {
                        InfoButton(title: title, description: info)
                    }
                    accessory
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            content
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    init(
        title: String? = nil,
        info: String? = nil,
        @ViewBuilder content: () -> Content
    ) where Accessory == EmptyView {
        self.title = title
        self.info = info
        self.content = content()
        accessory = EmptyView()
    }

    /// `accessory` renders right-aligned in the title row (e.g. the prompt
    /// history button) — only shown when `title` is non-nil.
    init(
        title: String? = nil,
        info: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.info = info
        self.content = content()
        self.accessory = accessory()
    }
}

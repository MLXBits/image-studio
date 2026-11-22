import SwiftUI

/// A tinted capsule carrying a size estimate: the model picker's RAM and disk
/// pills, and the Models window's per-quant download and RAM labels.
struct EstimatePill: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

import SwiftUI

// Small pieces shared by the LoRA library and stack editors.

/// Splits a comma-separated tag field into trimmed, non-empty tags.
func parseTags(_ raw: String) -> [String] {
    raw.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

struct RatingChip: View {
    let rating: LoraRating
    var body: some View {
        if rating != .unrated {
            Text(rating.label)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(color.opacity(0.2), in: Capsule())
                .foregroundStyle(color)
        }
    }

    private var color: Color {
        rating == .nsfw ? .pink : .green
    }
}

struct TagChips: View {
    let tags: [String]
    var body: some View {
        ForEach(tags, id: \.self) { tag in
            Text(tag)
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.fill.tertiary, in: Capsule())
                .foregroundStyle(.secondary)
        }
    }
}

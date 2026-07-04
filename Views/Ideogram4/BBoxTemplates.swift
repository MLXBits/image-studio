import Foundation

/// A named composition layout: a set of pre-placed object boxes the user relabels.
/// Coordinates are 0–1000 `[y_min, x_min, y_max, x_max]`, so a template renders
/// correctly at any output aspect ratio (the canvas is aspect-fitted).
///
/// These are deliberately *generic* — the overlapping-pair and foreground+background
/// layouts demonstrate depth/scale without encoding interaction semantics. They are
/// the bridge for judging whether curated multi-subject presets are still needed.
struct BBoxTemplate: Identifiable {
    static let library: [Self] = [
        Self(
            name: "Single subject",
            systemImage: "person.fill",
            elements: [obj([120, 300, 940, 700], "subject")]
        ),
        Self(
            name: "Portrait (rule of thirds)",
            systemImage: "person.crop.rectangle",
            elements: [obj([120, 100, 940, 540], "subject")]
        ),
        Self(
            name: "Two subjects (side by side)",
            systemImage: "person.2.fill",
            elements: [
                obj([200, 80, 880, 480], "left subject"),
                obj([200, 520, 880, 920], "right subject"),
            ]
        ),
        // Back subject first (drawn behind / earlier in JSON), front second (on top).
        Self(
            name: "Overlapping pair (front / back)",
            systemImage: "rectangle.on.rectangle",
            elements: [
                obj([140, 120, 900, 640], "subject behind"),
                obj([240, 400, 960, 880], "subject in front"),
            ]
        ),
        // Background element first (behind), foreground subject second (on top).
        Self(
            name: "Foreground + background",
            systemImage: "square.on.square",
            elements: [
                obj([80, 60, 720, 940], "background element"),
                obj([380, 300, 960, 720], "foreground subject"),
            ]
        ),
        Self(
            name: "Three subjects",
            systemImage: "person.3.fill",
            elements: [
                obj([240, 40, 800, 330], "left subject"),
                obj([180, 360, 860, 640], "center subject"),
                obj([240, 670, 800, 960], "right subject"),
            ]
        ),
    ]

    private static func obj(_ bbox: [Int], _ desc: String) -> IdeogramCaptionElement {
        IdeogramCaptionElement(type: .obj, bbox: bbox, desc: desc)
    }

    let id = UUID()
    let name: String
    let systemImage: String
    let elements: [IdeogramCaptionElement]
}

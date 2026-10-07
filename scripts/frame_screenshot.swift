#!/usr/bin/env swift
// Frames app window captures as App Store screenshots: a headline and a
// subtitle over a gradient, with one or two captures below, at exactly
// 2880 × 1800 (the largest Mac size App Store Connect accepts).
//
//   swift scripts/frame_screenshot.swift --title "Edit with a sentence." \
//     --subtitle "Describe the change; keep the rest." --theme violet \
//     --out edit.png before.png after.png
//
// Themes: violet, blue, teal, sunset, graphite.
import AppKit

struct Options {
    var title = ""
    var subtitle = ""
    var theme = "violet"
    var out = ""
    var inputs: [String] = []
}

func parse(_ args: [String]) -> Options {
    var options = Options()
    var index = 0
    func next() -> String {
        index += 1
        guard index < args.count else { fail("missing value after \(args[index - 1])") }
        return args[index]
    }
    while index < args.count {
        switch args[index] {
        case "--title": options.title = next()
        case "--subtitle": options.subtitle = next()
        case "--theme": options.theme = next()
        case "--out": options.out = next()
        default: options.inputs.append(args[index])
        }
        index += 1
    }
    guard !options.title.isEmpty, !options.out.isEmpty, (1 ... 2).contains(options.inputs.count) else {
        fail("usage: frame_screenshot.swift --title T [--subtitle S] [--theme NAME] --out OUT.png IMAGE [IMAGE2]")
    }
    return options
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1
    )
}

let themes: [String: (UInt32, UInt32)] = [
    "violet": (0x2A1146, 0x8E3CC8),
    "blue": (0x0B1E44, 0x2F6FDE),
    "teal": (0x06302F, 0x18A39A),
    "sunset": (0x3B0D2C, 0xE0603A),
    "graphite": (0x111214, 0x3A3D44),
]

let options = parse(Array(CommandLine.arguments.dropFirst()))
guard let (darkHex, lightHex) = themes[options.theme] else {
    fail("unknown theme \(options.theme); use one of \(themes.keys.sorted().joined(separator: ", "))")
}

let images: [NSImage] = options.inputs.map { path in
    guard let image = NSImage(contentsOfFile: path) else { fail("can't read \(path)") }
    return image
}

let width = 2880, height = 1800
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fail("can't create the canvas") }
rep.size = NSSize(width: width, height: height) // 1 point = 1 pixel
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
let canvas = NSRect(x: 0, y: 0, width: width, height: height)

// Background: a diagonal gradient, darker at the bottom.
NSGradient(starting: color(lightHex), ending: color(darkHex))?.draw(in: canvas, angle: -60)

/// Text, centred, near the top (AppKit's origin is bottom-left).
func drawCentered(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, top: CGFloat) -> CGFloat {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        .paragraphStyle: style,
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    let box = NSRect(x: 200, y: 0, width: CGFloat(width) - 400, height: 400)
    let used = string.boundingRect(with: box.size, options: [.usesLineFragmentOrigin, .usesFontLeading])
    string.draw(
        with: NSRect(x: box.minX, y: CGFloat(height) - top - used.height, width: box.width, height: used.height),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    return top + used.height
}

var textBottom = drawCentered(options.title, size: 112, weight: .bold, alpha: 1, top: 120)
if !options.subtitle.isEmpty {
    textBottom = drawCentered(options.subtitle, size: 52, weight: .medium, alpha: 0.82, top: textBottom + 24)
}

// Captures: fitted into the area below the text. Two overlap on a diagonal
// (the second, "after", in front), so each stays large.
let area = NSRect(x: 160, y: 110, width: CGFloat(width) - 320, height: CGFloat(height) - textBottom - 90 - 110)
func frame(for image: NSImage, index: Int) -> NSRect {
    let share: CGFloat = images.count == 1 ? 1 : 0.7
    let scale = min(area.width * share / image.size.width, area.height * (images.count == 1 ? 1 : 0.86) / image.size.height)
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    if images.count == 1 {
        return NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }
    // First: top-left of the area. Second: bottom-right.
    return index == 0
        ? NSRect(x: area.minX, y: area.maxY - size.height, width: size.width, height: size.height)
        : NSRect(x: area.maxX - size.width, y: area.minY, width: size.width, height: size.height)
}

for (i, image) in images.enumerated() {
    let frame = frame(for: image, index: i)
    let shape = NSBezierPath(roundedRect: frame, xRadius: 22, yRadius: 22)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = 60
    shadow.shadowOffset = NSSize(width: 0, height: -24)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fail("can't encode PNG") }
do {
    try png.write(to: URL(fileURLWithPath: options.out))
} catch {
    fail("can't write \(options.out): \(error.localizedDescription)")
}

print("\(options.out): \(width)×\(height)")

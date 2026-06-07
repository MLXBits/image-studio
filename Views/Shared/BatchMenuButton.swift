import AppKit
import SwiftUI

/// NSButton-backed drop-down menu button whose hit area matches its full visual frame.
/// SwiftUI's Menu hit-testing is AppKit-controlled and doesn't respect SwiftUI padding,
/// so this wrapper gives us reliable full-frame click targets.
struct BatchMenuButton: NSViewRepresentable {
    let counts: [Int]
    let shortcutCount: Int
    let isDisabled: Bool
    var onSelect: (Int) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .recessed
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .white
        button.target = context.coordinator
        button.action = #selector(Coordinator.clicked(_:))
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.isEnabled = !isDisabled
        context.coordinator.parent = self

        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        button.image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: "Batch generate"
        )?.withSymbolConfiguration(config)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    class Coordinator: NSObject {
        var parent: BatchMenuButton

        init(parent: BatchMenuButton) { self.parent = parent }

        @objc func clicked(_ sender: NSButton) {
            let menu = NSMenu()
            for count in parent.counts {
                let item = NSMenuItem(
                    title: "Generate \(count)",
                    action: #selector(selected(_:)),
                    keyEquivalent: count == parent.shortcutCount ? "g" : ""
                )
                if count == parent.shortcutCount {
                    item.keyEquivalentModifierMask = [.command, .shift]
                }
                item.target = self
                item.tag = count
                menu.addItem(item)
            }
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.height),
                in: sender
            )
        }

        @objc func selected(_ sender: NSMenuItem) {
            parent.onSelect(sender.tag)
        }
    }
}

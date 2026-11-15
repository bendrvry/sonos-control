import AppKit
import SwiftUI

enum MenuBarIcon {
    /// Apple's speaker pair symbol. As a template image, macOS colours it to match the menu bar.
    static let image: NSImage = {
        let image = NSImage(systemSymbolName: "hifispeaker.2.fill", accessibilityDescription: "Sonos Control")!
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))!
        image.isTemplate = true
        return image
    }()

    /// Lights the item up while the volume indicator is out, as macOS 26 lights its own volume item.
    /// AppKit draws no highlight for an item without an open menu, so the capsule is part of the template image
    /// and takes the menu bar's own tint. It fits the item's existing width, so nothing in the menu bar moves.
    static func highlight(_ item: NSStatusItem, _ on: Bool) {
        guard on, let bounds = item.button?.bounds else {
            item.button?.image = image
            return
        }
        let size = NSSize(width: bounds.width, height: min(22, bounds.height - 6))
        let pill = NSImage(size: size, flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            image.draw(in: NSRect(x: (rect.width - image.size.width) / 2, y: (rect.height - image.size.height) / 2,
                                  width: image.size.width, height: image.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        pill.isTemplate = true
        item.button?.image = pill
    }
}

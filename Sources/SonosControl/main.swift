import AppKit
import SwiftUI

// A plain status item and panel from MenuBarKit (rather than SwiftUI's MenuBarExtra), so the panel sits on
// real Liquid Glass, keeps its top edge pinned as it grows, and can open from code for `--demo`.
MainActor.assumeIsolated {
    // A menu bar app has no windows most of the time; don't let macOS treat that as idle and quit it.
    ProcessInfo.processInfo.disableAutomaticTermination("Lives in the menu bar")
    let controller = MenuBarController()
    NSApplication.shared.setActivationPolicy(.accessory)
    withExtendedLifetime(controller) { NSApplication.shared.run() }
}

@MainActor
final class MenuBarController: NSObject {
    /// `--demo` fills the panel with sample rooms and opens it. Nothing is sent to speakers.
    private let store = SpeakerStore(demo: CommandLine.arguments.contains("--demo"))
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private lazy var panel = MenuBarPanelController(item: item, content: SpeakerPanel(store: store))
#if BRIGHTNESS_KEYS
    private lazy var hud = VolumeHUD(store: store)
#endif

    override init() {
        super.init()
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        item.button?.image = MenuBarIcon.image
        item.button?.setAccessibilityLabel("Sonos Control")
        panel.onOpen = { [weak self] in
#if BRIGHTNESS_KEYS
            self?.hud.hide(animated: false)
#endif
            self?.store.panelDidOpen()
        }
        panel.onClose = { [weak self] in self?.store.panelDidClose() }
#if BRIGHTNESS_KEYS
        // The indicator only drops down while the panel is shut; with it open, its own slider moves.
        store.onVolumeKey = { [weak self] group in
            guard let self, !self.panel.isOpen else { return }
            self.hud.show(group, under: self.item)
        }
        if CommandLine.arguments.contains("--hud") { demoHUD() }
#endif
        if store.isDemo && !CommandLine.arguments.contains("--hud") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.panel.show() } }
    }

#if BRIGHTNESS_KEYS
    /// `--hud` (with `--demo`) shows the volume indicator over and over, as if the keys were pressed.
    private func demoHUD() {
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let group = self.store.volumeKeysTarget else { return }
                self.hud.show(group, under: self.item)
            }
        }.fire()
    }
#endif
}

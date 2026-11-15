// Brightness keys add-on. Built only with `bash scripts/build-app.sh --brightness-keys`
// (which passes -DBRIGHTNESS_KEYS). See "Add-on: brightness keys as volume keys" in the README.
#if BRIGHTNESS_KEYS
import AppKit
import SwiftUI
import SonosCore

/// The indicator that drops from the menu bar icon when the brightness keys change the volume.
/// It copies the volume indicator of macOS 26: a glass capsule centred under the menu bar item,
/// the output's name above a stepped slider between two speaker icons, gone a moment after the last press.
/// The slider is live, so it can also be dragged while the indicator is showing.
@MainActor
final class VolumeHUD {
    static let size = NSSize(width: 293, height: 62)
    static let radius: CGFloat = 20
    private static let gap: CGFloat = 11          // between the bottom of the menu bar and the top of the capsule
    private static let lingers: TimeInterval = 1.6

    private let store: SpeakerStore
    private let panel = HUDPanelWindow(size: VolumeHUD.size, clickThrough: false)
    private let hosting: NSHostingView<HUDContent>
    private let knob = KnobState()
    private var hideWork: DispatchWorkItem?
    private var hovering = false
    private weak var item: NSStatusItem?

    init(store: SpeakerStore) {
        self.store = store
        hosting = NSHostingView(rootView: HUDContent(store: store, knob: knob, group: nil, onHover: { _ in }))
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        hosting.autoresizingMask = [.width, .height]
        // The system indicator is dark lens glass with white type in light and dark mode alike (the window is dark).
        panel.contentView = HUDGlass.make(around: hosting, size: Self.size, cornerRadius: Self.radius, interactive: true)
    }

    var isVisible: Bool { panel.isVisible && panel.alphaValue > 0 }

    func show(_ group: SpeakerGroup, under item: NSStatusItem) {
        hosting.rootView = HUDContent(store: store, knob: knob, group: group, onHover: { [weak self] in self?.hover($0) })
        guard let button = item.button, button.window?.screen != nil else { return }
        let appearing = !isVisible
        if appearing {
            self.item = item
            MenuBarIcon.highlight(item, true)
        }
        present(under: button, animated: appearing)
        scheduleHide()
    }

    private func present(under button: NSStatusBarButton, animated: Bool) {
        guard let window = button.window, let screen = window.screen else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = Self.size
        let x = min(max(anchor.midX - size.width / 2, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        let frame = NSRect(x: x, y: anchor.minY - Self.gap - size.height, width: size.width, height: size.height)
        guard animated else {
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            return
        }
        // Grow out from just under the icon, the way the system's indicator unfolds from the menu bar.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let start = reduceMotion ? frame : NSRect(x: frame.midX - frame.width * 0.42, y: frame.maxY - frame.height * 0.8,
                                                  width: frame.width * 0.84, height: frame.height * 0.8)
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.15 : 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }
    }

    func hide(animated: Bool = true) {
        hideWork?.cancel()
        hideWork = nil
        if let item { MenuBarIcon.highlight(item, false) }
        item = nil
        guard panel.isVisible else { return }
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func hover(_ inside: Bool) {
        hovering = inside
        if inside { hideWork?.cancel() } else { scheduleHide() }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        guard !hovering else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lingers, execute: work)
    }
}

struct HUDContent: View {
    @ObservedObject var store: SpeakerStore
    let knob: KnobState
    let group: SpeakerGroup?
    let onHover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let group {
                let key = SpeakerStore.volumeKey(group), name = GroupPresentation.name(group)
                let muted = store.states[key]?.muted == true
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 7) {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.fill")
                        .frame(width: 14, alignment: .leading)
                    LevelBar(value: Binding(get: { Double(store.states[key]?.volume ?? 0) }, set: { store.changeVolume(key, $0) }),
                             knob: knob, label: "\(name) volume", isEnabled: !store.disabled(key), dimmed: muted,
                             onEditingChanged: { store.setEditing(key, $0) })
                    Image(systemName: "speaker.wave.3.fill")
                        .frame(width: 18, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 11)
        .frame(width: VolumeHUD.size.width, height: VolumeHUD.size.height, alignment: .topLeading)
        .hudBackdrop(cornerRadius: VolumeHUD.radius)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
    }
}

/// Whether the pointer is over the indicator's bar and whether it's held. Kept outside the view because
/// these apps build without the plugin `@State` needs.
@MainActor
final class KnobState: ObservableObject {
    @Published var hovering = false
    @Published var pressed = false
}

/// The indicator's bar: a thin capsule filled to the volume with a row of step dots beneath, as the system
/// indicator draws it. Like the system's, a white knob appears on it when the pointer is over the bar and
/// turns to clear Liquid Glass while it's held. It can be clicked or dragged, and works with VoiceOver.
struct LevelBar: View {
    @Binding var value: Double
    @ObservedObject var knob: KnobState
    let label: String
    let isEnabled: Bool
    let dimmed: Bool
    let onEditingChanged: (Bool) -> Void
    @Environment(\.colorScheme) private var scheme
    private static let steps = 16

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            VStack(spacing: 4) {
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(scheme == .dark ? 0.2 : 0.12))
                    Capsule().fill(fill).frame(width: max(0, min(1, value / 100)) * width)
                }
                .frame(height: 4)
                // An overlay, so the knob floats over the bar without changing its size or layout.
                .overlay(alignment: .leading) {
                    Knob(pressed: knob.pressed)
                        .offset(x: min(max(value / 100 * width, Knob.size.width / 2), width - Knob.size.width / 2) - Knob.size.width / 2)
                        .opacity(isEnabled && (knob.hovering || knob.pressed) ? 1 : 0)
                }
                HStack(spacing: 0) {
                    ForEach(0...Self.steps, id: \.self) { step in
                        Circle().fill(.primary.opacity(0.4)).frame(width: 2.5, height: 2.5)
                        if step < Self.steps { Spacer(minLength: 0) }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { knob.hovering = $0 }
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard isEnabled else { return }
                if !knob.pressed { knob.pressed = true }
                onEditingChanged(true)   // repeating this is harmless; it only marks the control as held
                value = (min(1, max(0, drag.location.x / max(width, 1))) * 100).rounded()
            }.onEnded { _ in
                knob.pressed = false
                onEditingChanged(false)
            })
        }
        .frame(height: 22)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.1), value: value)
        .animation(.easeOut(duration: 0.15), value: knob.hovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: knob.pressed)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(value.rounded())) percent")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            value = min(100, max(0, value + (direction == .increment ? 5 : -5)))
        }
    }

    private var fill: Color {
        let base = scheme == .dark ? Color.white : Color(white: 0.2)
        return dimmed ? base.opacity(0.4) : base
    }
}


/// The bar's knob: a small white capsule, which grows into a clear glass lens while it's held,
/// the way the system's sliders behave on macOS 26.
private struct Knob: View {
    static let size = CGSize(width: 22, height: 14)
    let pressed: Bool

    var body: some View {
        knob
            .frame(width: Self.size.width, height: Self.size.height)
            .scaleEffect(pressed ? 1.35 : 1)
            .allowsHitTesting(false)
    }

    @ViewBuilder private var knob: some View {
        if pressed, #available(macOS 26, *) {
            Capsule().fill(.white.opacity(0.08))
                .glassEffect(.clear, in: .capsule)
        } else {
            Capsule().fill(.white)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
        }
    }
}
#endif

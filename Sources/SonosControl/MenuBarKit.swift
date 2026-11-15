// MenuBarKit.swift · kit version 3
// Liquid Glass menu bar panels, HUDs and controls that look and behave like the system's own.
// This file is shared word for word between several menu bar apps. Change it in its source copy
// and sync it to every app, rather than editing one app's copy.

import AppKit
import SwiftUI

// MARK: - Metrics

enum PanelMetrics {
    static let width: CGFloat = 350
    static let cornerRadius: CGFloat = 18
    static let padding: CGFloat = 14
    static let spacing: CGFloat = 14
    /// Between the bottom of the menu bar and the top of the glass.
    static let gapBelowMenuBar: CGFloat = 6
    static let insetRadius: CGFloat = 13
    static let noticeRadius: CGFloat = 10
    static let hudRadius: CGFloat = 20
    /// Between the bottom of the menu bar and the top of a HUD capsule.
    static let hudGap: CGFloat = 11
    static let hudLinger: TimeInterval = 1.6
    /// Transparent room around the glass for the shadow Liquid Glass draws itself. The top stays small
    /// so the window never covers the menu bar.
    static let shadowRoom = NSEdgeInsets(top: gapBelowMenuBar, left: 24, bottom: 34, right: 24)
}

// MARK: - Type

/// San Francisco only, in a small set of sizes. No custom fonts, wordmarks or letter-spaced capitals.
extension Font {
    /// The app's name at the top of the panel.
    static let panelTitle = Font.system(size: 13, weight: .semibold)
    /// The main things the panel controls: a room, Lights, Music.
    static let sectionTitle = Font.system(size: 18, weight: .semibold)
    /// Folded groups and secondary headings: Other, Setup.
    static let subsectionTitle = Font.system(size: 15, weight: .semibold)
    static let rowLabel = Font.system(size: 13)
    static let rowDetail = Font.system(size: 12)
    static let note = Font.system(size: 11)
    static let largeValue = Font.system(size: 17).monospacedDigit()
    static let smallValue = Font.system(size: 13).monospacedDigit()
}

// MARK: - Panel window

/// A status item that opens a Liquid Glass panel under its icon, the way Control Center's modules open.
/// The panel grows downwards with its SwiftUI content, closes on Escape, on a click elsewhere, and on a
/// second click of the icon. Set `primaryClick` for apps whose icon does something on a plain click
/// (a right-, Control- or Option-click then opens the panel).
@MainActor
final class MenuBarPanelController: NSObject, NSWindowDelegate {
    let item: NSStatusItem
    let window = GlassPanelWindow()
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var primaryClick: (() -> Void)?
    var isOpen: Bool { window.isVisible }

    private let surface: GlassSurfaceView
    private let fittingSize: () -> NSSize
    private var closedAt = Date.distantPast

    init<Content: View>(item: NSStatusItem, content: Content) {
        self.item = item
        let host = SizingHostingView(rootView: content)
        fittingSize = { [unowned host] in host.fittingSize }
        surface = GlassSurfaceView(content: host, cornerRadius: PanelMetrics.cornerRadius, shadowRoom: PanelMetrics.shadowRoom)
        super.init()
        window.contentView = surface
        window.delegate = self
        window.onCancel = { [weak self] in self?.close() }
        surface.onClickOutsideGlass = { [weak self] in self?.close() }
        host.onResize = { [weak self] in if self?.isOpen == true { self?.position() } }
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        let wantsPanel = primaryClick == nil || event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true || event?.modifierFlags.contains(.option) == true
        guard wantsPanel else {
            close()
            primaryClick?()
            return
        }
        // Clicking the icon while the panel is open closes it on mouse-down; don't reopen it on mouse-up.
        if isOpen { close() } else if Date().timeIntervalSince(closedAt) > 0.25 { show() }
    }

    func show() {
        onOpen?()
        position()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard isOpen else { return }
        window.orderOut(nil)
        closedAt = Date()
        onClose?()
    }

    /// Centred under the icon, kept on screen, top edge fixed so the panel grows downwards.
    func position() {
        guard let button = item.button, let buttonWindow = button.window, let screen = buttonWindow.screen else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var size = fittingSize()
        let room = surface.shadowRoom
        let visible = screen.visibleFrame
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let glassTop = anchor.minY - PanelMetrics.gapBelowMenuBar
        // Taller than the screen allows: stop at the bottom (above the Dock) and let `PanelColumn` scroll.
        size.height = min(size.height, max(160, glassTop - visible.minY - 10))
        window.setFrame(NSRect(x: x - room.left, y: glassTop - size.height - room.bottom,
                               width: size.width + room.left + room.right, height: size.height + room.top + room.bottom),
                        display: true)
        if window.hasShadow { window.invalidateShadow() }
    }

    /// Set MENUBARKIT_KEEP_OPEN=1 to keep the panel open when focus moves away, for screenshots and checks
    /// (an app launched from a terminal isn't allowed to keep focus, so its panel would close at once).
    private static let keepsOpen = ProcessInfo.processInfo.environment["MENUBARKIT_KEEP_OPEN"] != nil

    func windowDidResignKey(_ notification: Notification) { if !Self.keepsOpen { close() } }
}

/// A borderless panel that can take keyboard focus (for sliders and text fields) and closes on Escape.
/// On macOS 26 and later it draws no shadow of its own: the glass draws a softer one, and a window shadow
/// adds the hard grey outline that makes the panel look boxed in.
final class GlassPanelWindow: NSPanel {
    var onCancel: (() -> Void)?
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = !GlassSurfaceView.drawsOwnShadow
        level = .popUpMenu
        collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Liquid Glass with room around it for its own shadow. The glass is never clipped: clipping cuts off
/// its rim and shadow, and a window the same size as the glass shows a rectangular shadow at the corners.
/// Before macOS 26 it falls back to the popover material with a rounded mask and the window's shadow.
final class GlassSurfaceView: NSView {
    static var drawsOwnShadow: Bool { if #available(macOS 26, *) { true } else { false } }
    let shadowRoom: NSEdgeInsets
    var onClickOutsideGlass: (() -> Void)?
    private let glass: NSView

    init(content: NSView, cornerRadius: CGFloat, shadowRoom: NSEdgeInsets) {
        self.shadowRoom = Self.drawsOwnShadow ? shadowRoom : NSEdgeInsets()
        if #available(macOS 26, *) {
            let view = NSGlassEffectView()
            view.style = .regular
            view.cornerRadius = cornerRadius
            view.contentView = content
            glass = view
        } else {
            let view = NSVisualEffectView()
            view.material = .popover
            view.state = .active
            view.wantsLayer = true
            view.layer?.cornerRadius = cornerRadius
            view.layer?.cornerCurve = .continuous
            view.layer?.masksToBounds = true
            content.frame = view.bounds
            content.autoresizingMask = [.width, .height]
            view.addSubview(content)
            glass = view
        }
        super.init(frame: .zero)
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        glass.frame = NSRect(x: shadowRoom.left, y: shadowRoom.bottom,
                             width: max(0, bounds.width - shadowRoom.left - shadowRoom.right),
                             height: max(0, bounds.height - shadowRoom.top - shadowRoom.bottom))
    }

    /// A click in the shadow around the glass counts as a click outside the panel.
    override func mouseDown(with event: NSEvent) {
        if !glass.frame.contains(convert(event.locationInWindow, from: nil)) { onClickOutsideGlass?() }
        else { super.mouseDown(with: event) }
    }
}

/// Reports when the SwiftUI content changes size, so the panel can grow and shrink with it.
final class SizingHostingView<Content: View>: NSHostingView<Content> {
    var onResize: (() -> Void)?
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onResize?() }
    }
}

// MARK: - HUD glass

/// The glass of the system's volume and brightness indicators: lens-like clear glass that bends what is
/// behind it and barely blurs it. Use it for transient confirmations that drop from the menu bar icon.
/// Put dark type on top with `.hudBackdrop()`, and give the HUD window `NSAppearance(named: .darkAqua)`.
enum HUDGlass {
    /// The glass's private lens variant (11, found on macOS 27 by comparing each variant with the real
    /// indicator). If a later macOS drops it, the glass stays plain clear glass.
    private static let lensVariant = 11

    static func make(around content: NSView, size: NSSize, cornerRadius: CGFloat = PanelMetrics.hudRadius,
                     interactive: Bool = false) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear
            if glass.responds(to: NSSelectorFromString("set_variant:")) { glass.setValue(lensVariant, forKey: "_variant") }
            glass.cornerRadius = cornerRadius
            if interactive, #available(macOS 27, *) { glass.effectIsInteractive = true }
            glass.contentView = content
            glass.frame = NSRect(origin: .zero, size: size)
            return glass
        }
        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.state = .active
        material.addSubview(content)
        material.frame = NSRect(origin: .zero, size: size)
        material.wantsLayer = true
        material.layer?.cornerRadius = cornerRadius
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        return material
    }

    /// Where a HUD of `size` sits under a menu bar icon, kept on screen.
    static func frame(size: NSSize, under anchor: NSRect, in screen: NSRect) -> NSRect {
        let x = min(max(anchor.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        return NSRect(x: x, y: anchor.minY - PanelMetrics.hudGap - size.height, width: size.width, height: size.height)
    }

    /// The frame a HUD grows from, just under the icon, the way the system indicator unfolds.
    static func unfoldStart(for frame: NSRect) -> NSRect {
        NSRect(x: frame.midX - frame.width * 0.42, y: frame.maxY - frame.height * 0.8,
               width: frame.width * 0.84, height: frame.height * 0.8)
    }
}

/// A HUD window: floats over everything, never takes focus, shows on every Space.
final class HUDPanelWindow: NSPanel {
    init(size: NSSize, clickThrough: Bool) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        ignoresMouseEvents = clickThrough
        appearance = NSAppearance(named: .darkAqua)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension View {
    /// The lens glass is nearly transparent, so white type would vanish over a white window. The system
    /// indicator dims what's behind it by about this much (measured against a screenshot of it over white).
    func hudBackdrop(cornerRadius: CGFloat = PanelMetrics.hudRadius) -> some View {
        background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Panel parts

/// A brand's own wordmark, for an app that controls that brand's product (Sonos Control shows "SONOS").
/// Only the brand's name uses it; the rest of the app stays in the system font. Never copy one app's
/// wordmark font into another app.
struct Wordmark {
    let text: String
    var font: Font = .custom("Futura-Medium", size: 13)
    var tracking: CGFloat = 1.6
}

/// The top row: the app's name in the system font and a "…" menu. Put a spinner or status in `accessory`.
/// With a `wordmark`, the brand comes first and `title` follows it ("SONOS" + "Control").
struct PanelHeader<Accessory: View, MenuItems: View>: View {
    let title: String
    var wordmark: Wordmark? = nil
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var menu: () -> MenuItems

    var body: some View {
        HStack(spacing: 6) {
            titleView.accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            accessory()
            Menu { menu() } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium)).frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More options")
        }
        .padding(.top, 10)
    }

    @ViewBuilder private var titleView: some View {
        if let wordmark {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(wordmark.text).font(wordmark.font).tracking(wordmark.tracking)
                Text(title).font(.system(size: 13))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(wordmark.text.capitalized) \(title)")
        } else {
            Text(title).font(.panelTitle)
        }
    }
}

extension PanelHeader where Accessory == EmptyView {
    init(title: String, @ViewBuilder menu: @escaping () -> MenuItems) {
        self.init(title: title, accessory: { EmptyView() }, menu: menu)
    }
}

/// The standard panel column: fixed width, standard padding, grows to fit. The panel never scrolls
/// unless it would run past the bottom of the screen; then it stops there and scrolls, with no scroll bar.
struct PanelColumn<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ViewThatFits(in: .vertical) {
            column
            ScrollView(.vertical, showsIndicators: false) { column }
        }
    }
    private var column: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.spacing, content: content)
            .padding(.horizontal, PanelMetrics.padding).padding(.bottom, PanelMetrics.padding)
            .frame(width: PanelMetrics.width)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A hairline between sections.
struct PanelDivider: View {
    var body: some View { Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5) }
}

/// The chevron that turns when a section opens.
struct DisclosureChevron: View {
    let expanded: Bool
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(width: 12)
            .rotationEffect(.degrees(expanded ? 90 : 0))
    }
}

/// A heading that folds a section away, with a short summary on the right while it is folded.
struct DisclosureRow: View {
    let title: String
    let expanded: Bool
    var summary: String? = nil
    var summaryColor: Color = .secondary
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 9) {
                DisclosureChevron(expanded: expanded)
                Text(title).font(.subsectionTitle)
                Spacer()
                if !expanded, let summary { Text(summary).font(.rowDetail).foregroundStyle(summaryColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(expanded ? "Hide" : "Show") \(title)")
    }
}

/// The grey inset surface for secondary content inside the glass: a group of speakers, a setup list.
struct InsetSurface: ViewModifier {
    var cornerRadius: CGFloat = PanelMetrics.insetRadius
    var hairline = true
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(Color.insetFill(scheme), in: shape)
            .overlay(shape.strokeBorder(.primary.opacity(hairline ? 0.07 : 0), lineWidth: 0.5))
    }
}

extension Color {
    static func insetFill(_ scheme: ColorScheme) -> Color { scheme == .dark ? .white.opacity(0.06) : .black.opacity(0.035) }
}

extension View {
    func insetSurface(cornerRadius: CGFloat = PanelMetrics.insetRadius, hairline: Bool = true) -> some View {
        modifier(InsetSurface(cornerRadius: cornerRadius, hairline: hairline))
    }
}

/// An inset group of rows with the standard padding.
struct InsetGroup<Content: View>: View {
    var spacing: CGFloat = 7
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: spacing, content: content)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .insetSurface()
    }
}

/// A short message inside the panel. Orange for problems, plain for information.
struct PanelNotice: View {
    let text: String
    var systemImage = "exclamationmark.circle"
    var isProblem = true
    var onDismiss: (() -> Void)? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage).foregroundStyle(isProblem ? Color.orange : .secondary)
            Text(text).font(.note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss").accessibilityLabel("Dismiss")
            }
        }
        .padding(10)
        .background(isProblem ? Color.orange.opacity(0.08) : Color.insetFill(scheme),
                    in: RoundedRectangle(cornerRadius: PanelMetrics.noticeRadius, style: .continuous))
    }
}

// MARK: - Controls

/// A round Liquid Glass icon button: mute, play, lights on. Pass `tint` only for a meaningful state
/// (yellow for lights on, red while recording); otherwise it stays monochrome.
struct GlassIconButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 30
    var tint: Color? = nil
    var dimmed = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.43))
                .foregroundStyle(tint ?? (dimmed ? Color.secondary : Color.primary))
                .frame(width: size, height: size)
                .contentShape(Circle())
                .glassCircle()
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

/// A Liquid Glass capsule for a choice such as a lighting scene.
struct GlassChip: View {
    let title: String
    var help: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.rowDetail).padding(.horizontal, 11).frame(height: 26)
                .contentShape(Capsule()).glassCapsule()
        }
        .buttonStyle(.plain).help(help ?? title).accessibilityLabel(title)
    }
}

extension View {
    /// Liquid Glass on macOS 26 and later; a flat inset shape before that.
    @ViewBuilder func glassCircle() -> some View {
        if #available(macOS 26, *) { glassEffect(.regular.interactive(), in: .circle) } else { modifier(FallbackFill(shape: Circle())) }
    }
    @ViewBuilder func glassCapsule() -> some View {
        if #available(macOS 26, *) { glassEffect(.regular.interactive(), in: .capsule) } else { modifier(FallbackFill(shape: Capsule())) }
    }
}

private struct FallbackFill<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View { content.background(Color.insetFill(scheme), in: shape) }
}

/// The stock slider, so it picks up the Liquid Glass knob and track on macOS 26 and later along with its
/// keyboard, accessibility and tracking behaviour. Only the fill is made neutral, as in Control Center.
/// Use height 25 for a main slider (`prominent`) and 21 for a row slider.
struct ControlSlider: NSViewRepresentable {
    @Binding var value: Double
    var label: String
    var isEnabled = true
    var prominent = false
    var onEditingChanged: (Bool) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> TrackingSlider {
        let slider = TrackingSlider()
        slider.controlSize = prominent ? .regular : .small
        slider.trackFillColor = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : NSColor(white: 0.25, alpha: 1) }
        slider.minValue = 0; slider.maxValue = 100
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.editingChanged = { context.coordinator.parent.onEditingChanged($0) }
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }
    func updateNSView(_ slider: TrackingSlider, context: Context) {
        context.coordinator.parent = self
        if slider.doubleValue != value { slider.doubleValue = value }
        slider.isEnabled = isEnabled
        slider.setAccessibilityLabel(label)
        slider.setAccessibilityValueDescription("\(Int(value.rounded())) percent")
    }
    final class Coordinator: NSObject {
        var parent: ControlSlider
        init(_ parent: ControlSlider) { self.parent = parent }
        @objc func changed(_ slider: NSSlider) { parent.value = slider.doubleValue.rounded() }
    }
}

final class TrackingSlider: NSSlider {
    var editingChanged: ((Bool) -> Void)?
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        editingChanged?(true); super.mouseDown(with: event); editingChanged?(false)
    }
    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        editingChanged?(true); super.keyDown(with: event); editingChanged?(false)
    }
    /// A sideways two-finger swipe nudges the value, as it does in Control Center.
    /// Vertical scrolling is left to the panel.
    override func scrollWheel(with event: NSEvent) {
        guard isEnabled, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return super.scrollWheel(with: event) }
        let direction: Double = event.isDirectionInvertedFromDevice ? 1 : -1
        doubleValue += direction * event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 0.25 : 2)
        sendAction(action, to: target)
    }
}

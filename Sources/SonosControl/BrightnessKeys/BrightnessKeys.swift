// Brightness keys add-on. Built only with `bash scripts/build-app.sh --brightness-keys`
// (which passes -DBRIGHTNESS_KEYS). See "Add-on: brightness keys as volume keys" in the README.
#if BRIGHTNESS_KEYS
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

private let log = Logger(subsystem: "io.github.bendrvry.SonosControl", category: "keys")

/// Turns the brightness keys (F1 and F2 on Apple keyboards) into volume down and up.
/// Taking keys away from the system needs Accessibility permission; without it `start()` fails.
@MainActor
final class VolumeKeys {
    private let onPress: (Int) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(onPress: @escaping (Int) -> Void) { self.onPress = onPress }

    var isRunning: Bool { tap != nil }

    /// Returns false until the user allows Sonos Control under Privacy & Security → Accessibility.
    @discardableResult func start(prompt: Bool) -> Bool {
        guard tap == nil else { return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            log.info("Not trusted for Accessibility yet")
            return false
        }
        let mask = CGEventMask(1 << 14) | CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: handle,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log.error("Couldn't create the event tap")
            return false
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        log.info("Listening for the brightness keys")
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        self.tap = nil
        source = nil
    }

    /// Volume step for a press, 0 for an event this class swallows silently (key up), nil to let it through.
    /// Brightness keys reach apps in different ways depending on the keyboard and its settings, so all of them count.
    fileprivate static func step(for type: CGEventType, _ event: CGEvent) -> Int? {
        let step = 2
        if type.rawValue == 14 {
            guard let system = NSEvent(cgEvent: event), system.subtype.rawValue == 8 else { return nil }
            // NX_KEYTYPE_BRIGHTNESS_UP is 2 and _DOWN is 3; key state 0xA is down, 0xB is up.
            let code = (system.data1 & 0xFFFF0000) >> 16, down = (system.data1 & 0xFF00) >> 8 == 0xA
            log.debug("System key \(code, privacy: .public) \(down ? "down" : "up", privacy: .public)")
            switch code {
            case 2: return down ? step : 0
            case 3: return down ? -step : 0
            default: return nil
            }
        }
        guard type == .keyDown || type == .keyUp else { return nil }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        // Only special keys are ever logged (function keys and above), never ordinary typing.
        if (code >= kVK_F5 && !(kVK_LeftArrow...kVK_UpArrow).contains(code)) || [kVK_F17, kVK_F18, kVK_F19, kVK_F20].contains(code) {
            log.debug("Key \(code, privacy: .public) \(type == .keyDown ? "down" : "up", privacy: .public)")
        }
        guard event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else { return nil }
        let down = type == .keyDown
        switch code {
        case kVK_F1, kVK_F14, 145: return down ? -step : 0   // 145 and 144 are the brightness keys' own codes.
        case kVK_F2, kVK_F15, 144: return down ? step : 0
        default: return nil
        }
    }

    fileprivate func reenable() {
        log.info("Event tap was paused by the system; turning it back on")
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
    fileprivate func press(_ step: Int) { onPress(step) }
}

private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let info else { return Unmanaged.passUnretained(event) }
    let keys = Unmanaged<VolumeKeys>.fromOpaque(info).takeUnretainedValue()
    // The tap runs on the main run loop, so it is safe to touch main-actor state here.
    return MainActor.assumeIsolated {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            keys.reenable()
            return Unmanaged.passUnretained(event)
        }
        guard let step = VolumeKeys.step(for: type, event) else { return Unmanaged.passUnretained(event) }
        if step != 0 { keys.press(step) }
        return nil
    }
}
#endif

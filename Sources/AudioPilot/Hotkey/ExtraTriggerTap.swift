import AppKit
import CoreGraphics
import AudioPilotCore
import os

/// Listens (never blocks) for the Globe key or an extra mouse button via a listen-only event tap,
/// which needs Input Monitoring permission. The Globe key only counts as a tap when no other key
/// was pressed while it was held, so fn+key combos keep working.
final class ExtraTriggerTap {
    var onPress: () -> Void = {}
    /// `wasTap` is false when the Globe key was used as a modifier (fn+key) while held.
    var onRelease: (_ wasTap: Bool) -> Void = { _ in }
    private(set) var trigger: ExtraTrigger = .none
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var fnDown = false
    private var fnUsedAsModifier = false
    private let logger = Logger(subsystem: "com.techenable.audiopilot", category: "trigger")

    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    /// Prompts for Input Monitoring (opens the System Settings prompt the first time).
    @discardableResult
    static func requestPermission() -> Bool { CGRequestListenEventAccess() }

    /// Installs the tap for `trigger`. Returns false if permission is missing.
    @discardableResult
    func start(_ trigger: ExtraTrigger) -> Bool {
        stop()
        self.trigger = trigger
        guard trigger != .none else { return true }
        guard Self.hasPermission else {
            Self.requestPermission()
            return false
        }
        var mask: CGEventMask = 0
        if trigger == .globe {
            mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        } else {
            mask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: extraTriggerCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            logger.error("event tap creation failed")
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        fnDown = false
    }

    /// The parts of a CGEvent the tap needs, copied out so no event object crosses actors.
    fileprivate struct Info: Sendable {
        let type: CGEventType
        let keyCode: Int64
        let fn: Bool
        let button: Int64
    }

    fileprivate func handle(_ e: Info) {
        let type = e.type
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged where trigger == .globe:
            let down = e.fn
            // Arrow and function keys also set the fn flag; only react to the Globe key itself (63).
            guard e.keyCode == 63 else { return }
            if down && !fnDown {
                fnDown = true
                fnUsedAsModifier = false
                onPress()
            } else if !down && fnDown {
                fnDown = false
                onRelease(!fnUsedAsModifier)
            }
        case .keyDown where fnDown:
            fnUsedAsModifier = true
        case .otherMouseDown where e.button == trigger.mouseButton:
            onPress()
        case .otherMouseUp where e.button == trigger.mouseButton:
            onRelease(true)
        default:
            break
        }
    }
}

private nonisolated func extraTriggerCallback(_: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                                              _ userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let tap = Unmanaged<ExtraTriggerTap>.fromOpaque(userInfo).takeUnretainedValue()
        let info = ExtraTriggerTap.Info(type: type,
                                        keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                                        fn: event.flags.contains(.maskSecondaryFn),
                                        button: event.getIntegerValueField(.mouseEventButtonNumber))
        MainActor.assumeIsolated { tap.handle(info) }
    }
    return Unmanaged.passUnretained(event)
}

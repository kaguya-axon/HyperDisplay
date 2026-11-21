import Foundation
import CoreGraphics

final class InputInjector {
    private var virtualDisplayID: CGDirectDisplayID = 0
    private var lastPinchZoomTime: CFAbsoluteTime = 0

    func setDisplayID(_ id: CGDirectDisplayID) {
        virtualDisplayID = id
    }

    func handle(_ input: TouchInputPacket) {
        guard virtualDisplayID != 0 else { return }
        let bounds = CGDisplayBounds(virtualDisplayID)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let nx = max(0.0, min(1.0, Double(input.normX)))
        let ny = max(0.0, min(1.0, Double(input.normY)))
        let point = CGPoint(
            x: bounds.origin.x + nx * bounds.width,
            y: bounds.origin.y + ny * bounds.height
        )

        let source = CGEventSource(stateID: .hidSystemState)

        switch input.kind {
        case .mouseMoved:
            if let ev = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
                applyPencilMetadataIfNeeded(ev, input: input)
                ev.post(tap: .cghidEventTap)
            }

        case .leftClick:
            let clicks = Int64(max(1, input.clickCount))
            // Move cursor first so macOS hover/focus targets update cleanly before click.
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            if let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
                down.setIntegerValueField(.mouseEventClickState, value: clicks)
                applyPencilMetadataIfNeeded(down, input: input)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
                up.setIntegerValueField(.mouseEventClickState, value: clicks)
                applyPencilMetadataIfNeeded(up, input: input)
                up.post(tap: .cghidEventTap)
            }

        case .leftDown:
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            if let ev = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
                ev.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, input.clickCount)))
                applyPencilMetadataIfNeeded(ev, input: input)
                ev.post(tap: .cghidEventTap)
            }

        case .leftDragged:
            if let ev = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) {
                applyPencilMetadataIfNeeded(ev, input: input)
                ev.post(tap: .cghidEventTap)
            }

        case .leftUp:
            if let ev = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
                ev.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, input.clickCount)))
                applyPencilMetadataIfNeeded(ev, input: input)
                ev.post(tap: .cghidEventTap)
            }

        case .rightClick:
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: source, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)?
                .post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)?
                .post(tap: .cghidEventTap)

        case .scroll:
            // Pixel-smooth continuous scrolling matching macOS touchscreen & trackpad natural scrolling.
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            let dy = Int32(input.deltaY.rounded())
            let dx = Int32(input.deltaX.rounded())
            if let ev = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) {
                ev.location = point
                ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                ev.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(input.deltaY))
                ev.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(input.deltaX))
                // Map phase (1=began, 2=changed, 3=ended, 4=momentum)
                switch input.phase {
                case 1: ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
                case 2: ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
                case 3: ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
                case 4: ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
                default: break
                }
                ev.post(tap: .cghidEventTap)
            }

        case .pinchZoom:
            // Trigger Cmd + / Cmd - with gentle throttle for smooth pinch-to-zoom across macOS apps.
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastPinchZoomTime >= 0.09 else { return }
            lastPinchZoomTime = now
            // Ensure cursor is over target window.
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            let keyCode: CGKeyCode = input.deltaY >= 0 ? 24 : 27 // '=' (+) or '-'
            postKeyCombo(source: source, keyCode: keyCode, flags: .maskCommand)

        case .missionControl:
            // macOS 27 Touchscreen 3-finger swipe up -> Mission Control (Ctrl + Up)
            postKeyCombo(source: source, keyCode: 126, flags: .maskControl)

        case .switchSpaceLeft:
            // macOS 27 Touchscreen 3-finger swipe right -> Previous Space (Ctrl + Left)
            postKeyCombo(source: source, keyCode: 123, flags: .maskControl)

        case .switchSpaceRight:
            // macOS 27 Touchscreen 3-finger swipe left -> Next Space (Ctrl + Right)
            postKeyCombo(source: source, keyCode: 124, flags: .maskControl)
        }
    }

    private func applyPencilMetadataIfNeeded(_ ev: CGEvent, input: TouchInputPacket) {
        guard input.isPencil else { return }
        ev.setIntegerValueField(.mouseEventSubtype, value: 1) // NX_SUBTYPE_TABLET_POINT
        let p = max(0.0, min(1.0, Double(input.pressure)))
        ev.setDoubleValueField(.tabletEventPointPressure, value: p)
    }

    private func postKeyCombo(source: CGEventSource?, keyCode: CGKeyCode, flags: CGEventFlags) {
        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }
}

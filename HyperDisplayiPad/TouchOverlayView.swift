import UIKit
import AVFoundation

/// Implements macOS 27 Touchscreen MacBook Pro direct-touch ergonomics + native Apple Pencil Pro support:
///
/// Finger Touch:
/// - Single tap / double tap / triple tap -> left click (clickCount 1/2/3)
/// - Single-finger drag immediately -> natural pixel-smooth scrolling with 120Hz momentum inertia
/// - Hold ~0.22s then drag (or double-tap & hold drag) -> left-button drag (windows, text selection)
/// - Hold still ~0.50s -> right-click context menu (with subtle haptic/ring cue)
/// - Two-finger tap -> right click
/// - Two-finger pinch -> zoom (Cmd + / Cmd -)
/// - Two-finger pan -> precision scroll
/// - Three-finger swipe up -> Mission Control
/// - Three-finger swipe left/right -> Switch Desktop Spaces
/// - Three-finger tap -> Toggle HUD overlay
///
/// Apple Pencil (automatically distinguished via touch.type == .pencil):
/// - Hover (M4 iPad Pro) -> real-time mouse cursor move without clicking
/// - Touch down / drag / up -> direct precision left click / drag / drawing with hardware pressure
/// - Pencil Pro squeeze or Pencil 2 double-tap -> right click at hover/last point
final class TouchOverlayView: UIView, UIPencilInteractionDelegate {
    var onTouchInput: ((TouchInputPacket) -> Void)?
    var onToggleHUD: (() -> Void)?

    private var videoAspectSize: CGSize = CGSize(width: 2420, height: 1668)

    // Finger state machine
    private enum FingerMode {
        case idle
        case pending       // touched down, waiting to disambiguate tap / scroll / hold-drag / long-press
        case scrolling     // natural direct-touch scroll
        case dragging      // left mouse button held down & dragging
        case multiTouch    // >=2 fingers handled by gesture recognizers
    }

    private var fingerMode: FingerMode = .idle
    private var primaryFinger: UITouch?
    private var fingerStartPoint: CGPoint = .zero
    private var fingerLastPoint: CGPoint = .zero
    private var fingerLastTime: CFTimeInterval = 0
    private var scrollVelocity: CGPoint = .zero
    private var lastTapPoint: CGPoint = .zero
    private var lastTapTime: CFTimeInterval = 0
    private var tapStreak: UInt8 = 0
    private var holdToDragTimer: DispatchWorkItem?
    private var longPressRightClickTimer: DispatchWorkItem?

    // Momentum inertia display link (120Hz smooth coasting after finger lift)
    private var momentumLink: CADisplayLink?
    private var momentumAnchorPoint: CGPoint = .zero

    // Apple Pencil state
    private var activePencil: UITouch?
    private var lastPencilHoverPoint: CGPoint?
    private var lastPencilTapTime: CFTimeInterval = 0
    private var pencilClickStreak: UInt8 = 1

    // Gesture tracking
    private var lastTwoFingerPanPoint: CGPoint = .zero
    private var lastPinchScale: CGFloat = 1.0
    private var threeFingerStartPoint: CGPoint = .zero
    private var threeFingerTriggered = false

    // Subtle visual ring for drag / right-click confirmation
    private let feedbackRing = CAShapeLayer()
    private let hapticLight = UIImpactFeedbackGenerator(style: .light)
    private let hapticMedium = UIImpactFeedbackGenerator(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    func updateVideoAspect(pixelWidth: Int, pixelHeight: Int) {
        guard pixelWidth > 0, pixelHeight > 0 else { return }
        videoAspectSize = CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
    }

    private func commonInit() {
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        feedbackRing.fillColor = UIColor.clear.cgColor
        feedbackRing.strokeColor = UIColor.systemCyan.withAlphaComponent(0.85).cgColor
        feedbackRing.lineWidth = 2.5
        feedbackRing.opacity = 0
        layer.addSublayer(feedbackRing)

        // Apple Pencil hover (M2/M4 iPad Pro)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)

        // Apple Pencil Pro squeeze / Pencil 2 double-tap -> right click
        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = self
        addInteraction(pencilInteraction)

        // Two-finger tap -> Right click
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.cancelsTouchesInView = false
        addGestureRecognizer(twoFingerTap)

        // Three-finger tap -> Toggle HUD
        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap(_:)))
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.cancelsTouchesInView = false
        addGestureRecognizer(threeFingerTap)

        // Two-finger pinch -> Zoom (Cmd + / -)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        addGestureRecognizer(pinch)

        // Two-finger pan -> Precision scroll
        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.cancelsTouchesInView = false
        addGestureRecognizer(twoFingerPan)

        // Three-finger pan -> Mission Control (up) & Switch Spaces (left/right)
        let threeFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleThreeFingerPan(_:)))
        threeFingerPan.minimumNumberOfTouches = 3
        threeFingerPan.maximumNumberOfTouches = 3
        threeFingerPan.cancelsTouchesInView = false
        addGestureRecognizer(threeFingerPan)
    }

    // Map touch point strictly into the actual aspect-fitted video rect (zero letterbox drift).
    private func normalizedVideoPoint(_ pt: CGPoint) -> (Float, Float) {
        guard bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        let videoRect = AVMakeRect(aspectRatio: videoAspectSize, insideRect: bounds)
        guard videoRect.width > 0, videoRect.height > 0 else { return (0, 0) }
        let nx = Float(max(0, min(1, (pt.x - videoRect.minX) / videoRect.width)))
        let ny = Float(max(0, min(1, (pt.y - videoRect.minY) / videoRect.height)))
        return (nx, ny)
    }

    private func showFeedbackRing(at pt: CGPoint, color: UIColor) {
        let r: CGFloat = 24
        feedbackRing.strokeColor = color.cgColor
        feedbackRing.path = UIBezierPath(ovalIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)).cgPath
        feedbackRing.opacity = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.duration = 0.28
        feedbackRing.add(fade, forKey: "ringFade")
        feedbackRing.opacity = 0
    }

    // MARK: - Touch Handling (Finger vs Apple Pencil)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopMomentumScroll()

        // 1. Apple Pencil gets dedicated immediate precision control with pressure.
        if let pencil = touches.first(where: { $0.type == .pencil }) {
            cancelFingerTimers()
            activePencil = pencil
            let pt = pencil.location(in: self)
            lastPencilHoverPoint = pt
            let now = CACurrentMediaTime()
            if now - lastPencilTapTime < 0.32 {
                pencilClickStreak = min(3, pencilClickStreak + 1)
            } else {
                pencilClickStreak = 1
            }
            lastPencilTapTime = now
            let (nx, ny) = normalizedVideoPoint(pt)
            let p = normalizedPencilPressure(pencil)
            onTouchInput?(TouchInputPacket(
                kind: .leftDown, normX: nx, normY: ny,
                pressure: p, isPencil: true, clickCount: pencilClickStreak
            ))
            return
        }

        // 2. Finger touches
        let fingerTouches = (event?.allTouches ?? touches).filter { $0.type != .pencil && $0.phase != .ended && $0.phase != .cancelled }
        if fingerTouches.count > 1 {
            cancelFingerTimers()
            if fingerMode == .dragging, let f = primaryFinger {
                let (nx, ny) = normalizedVideoPoint(f.location(in: self))
                onTouchInput?(TouchInputPacket(kind: .leftUp, normX: nx, normY: ny))
            }
            primaryFinger = nil
            fingerMode = .multiTouch
            return
        }

        guard let finger = touches.first(where: { $0.type != .pencil }) else { return }
        primaryFinger = finger
        let pt = finger.location(in: self)
        fingerStartPoint = pt
        fingerLastPoint = pt
        fingerLastTime = CACurrentMediaTime()
        scrollVelocity = .zero

        // Double-tap-and-hold shortcut: if user taps quickly a second time right on the same spot, enter drag immediately on move.
        let now = CACurrentMediaTime()
        let isNearLastTap = hypot(pt.x - lastTapPoint.x, pt.y - lastTapPoint.y) < 32
        if (now - lastTapTime) < 0.28 && isNearLastTap {
            fingerMode = .dragging
            let (nx, ny) = normalizedVideoPoint(pt)
            onTouchInput?(TouchInputPacket(kind: .leftDown, normX: nx, normY: ny, clickCount: 1))
            return
        }

        fingerMode = .pending

        // Schedule Hold-to-Drag (0.22s dwell -> enters window/text drag mode like touchscreen macOS)
        let dragTimer = DispatchWorkItem { [weak self] in
            guard let self, self.fingerMode == .pending, let f = self.primaryFinger else { return }
            let cur = f.location(in: self)
            guard hypot(cur.x - self.fingerStartPoint.x, cur.y - self.fingerStartPoint.y) < 12 else { return }
            self.fingerMode = .dragging
            self.hapticLight.impactOccurred()
            self.showFeedbackRing(at: cur, color: .systemCyan)
            let (nx, ny) = self.normalizedVideoPoint(cur)
            self.onTouchInput?(TouchInputPacket(kind: .leftDown, normX: nx, normY: ny, clickCount: 1))
        }
        holdToDragTimer = dragTimer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: dragTimer)

        // Schedule Long-Press Right Click (0.55s dwell without moving -> context menu)
        let rightTimer = DispatchWorkItem { [weak self] in
            guard let self, self.fingerMode == .dragging, let f = self.primaryFinger else { return }
            let cur = f.location(in: self)
            guard hypot(cur.x - self.fingerStartPoint.x, cur.y - self.fingerStartPoint.y) < 10 else { return }
            // Release left hold and fire right-click context menu.
            let (nx, ny) = self.normalizedVideoPoint(cur)
            self.onTouchInput?(TouchInputPacket(kind: .leftUp, normX: nx, normY: ny))
            self.onTouchInput?(TouchInputPacket(kind: .rightClick, normX: nx, normY: ny))
            self.hapticMedium.impactOccurred()
            self.showFeedbackRing(at: cur, color: .systemOrange)
            self.fingerMode = .multiTouch // consume until lift
        }
        longPressRightClickTimer = rightTimer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: rightTimer)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 1. Apple Pencil high-rate coalesced tracking (240Hz -> 120Hz smooth strokes)
        if let pencil = activePencil, touches.contains(pencil) {
            let pt = pencil.location(in: self)
            lastPencilHoverPoint = pt
            let (nx, ny) = normalizedVideoPoint(pt)
            let p = normalizedPencilPressure(pencil)
            onTouchInput?(TouchInputPacket(kind: .leftDragged, normX: nx, normY: ny, pressure: p, isPencil: true))
            return
        }

        // 2. Finger move
        guard let finger = primaryFinger, touches.contains(finger) else { return }
        let pt = finger.location(in: self)
        let now = CACurrentMediaTime()
        let dt = max(0.001, now - fingerLastTime)

        switch fingerMode {
        case .pending:
            let moved = hypot(pt.x - fingerStartPoint.x, pt.y - fingerStartPoint.y)
            if moved > 9.0 {
                // Immediate finger slide = natural scrolling (macOS 27 Touchscreen / iPad ergonomics)
                cancelFingerTimers()
                fingerMode = .scrolling
                let dx = Float((pt.x - fingerLastPoint.x) * 2.0)
                let dy = Float((pt.y - fingerLastPoint.y) * 2.0)
                let (nx, ny) = normalizedVideoPoint(pt)
                onTouchInput?(TouchInputPacket(kind: .scroll, normX: nx, normY: ny, deltaX: dx, deltaY: dy, phase: 1))
                scrollVelocity = CGPoint(x: (pt.x - fingerLastPoint.x) / dt, y: (pt.y - fingerLastPoint.y) / dt)
                fingerLastPoint = pt
                fingerLastTime = now
            }

        case .scrolling:
            let stepX = pt.x - fingerLastPoint.x
            let stepY = pt.y - fingerLastPoint.y
            let (nx, ny) = normalizedVideoPoint(pt)
            onTouchInput?(TouchInputPacket(
                kind: .scroll, normX: nx, normY: ny,
                deltaX: Float(stepX * 2.0), deltaY: Float(stepY * 2.0),
                phase: 2
            ))
            let instVx = stepX / dt
            let instVy = stepY / dt
            scrollVelocity = CGPoint(
                x: scrollVelocity.x * 0.45 + instVx * 0.55,
                y: scrollVelocity.y * 0.45 + instVy * 0.55
            )
            fingerLastPoint = pt
            fingerLastTime = now

        case .dragging:
            if hypot(pt.x - fingerStartPoint.x, pt.y - fingerStartPoint.y) > 12 {
                longPressRightClickTimer?.cancel()
                longPressRightClickTimer = nil
            }
            let (nx, ny) = normalizedVideoPoint(pt)
            onTouchInput?(TouchInputPacket(kind: .leftDragged, normX: nx, normY: ny))
            fingerLastPoint = pt
            fingerLastTime = now

        case .idle, .multiTouch:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let pencil = activePencil, touches.contains(pencil) {
            let pt = pencil.location(in: self)
            lastPencilHoverPoint = pt
            activePencil = nil
            let (nx, ny) = normalizedVideoPoint(pt)
            onTouchInput?(TouchInputPacket(
                kind: .leftUp, normX: nx, normY: ny,
                pressure: 0, isPencil: true, clickCount: pencilClickStreak
            ))
            return
        }

        guard let finger = primaryFinger, touches.contains(finger) else {
            let remaining = (event?.allTouches ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }
            if remaining.isEmpty { fingerMode = .idle }
            return
        }

        cancelFingerTimers()
        let pt = finger.location(in: self)
        let (nx, ny) = normalizedVideoPoint(pt)

        switch fingerMode {
        case .pending:
            // Clean single tap (or double / triple tap)
            let now = CACurrentMediaTime()
            if (now - lastTapTime) < 0.34 && hypot(pt.x - lastTapPoint.x, pt.y - lastTapPoint.y) < 36 {
                tapStreak = min(3, tapStreak + 1)
            } else {
                tapStreak = 1
            }
            lastTapTime = now
            lastTapPoint = pt
            onTouchInput?(TouchInputPacket(kind: .leftClick, normX: nx, normY: ny, clickCount: tapStreak))

        case .scrolling:
            onTouchInput?(TouchInputPacket(kind: .scroll, normX: nx, normY: ny, deltaX: 0, deltaY: 0, phase: 3))
            startMomentumScroll(anchor: pt)

        case .dragging:
            onTouchInput?(TouchInputPacket(kind: .leftUp, normX: nx, normY: ny))

        case .idle, .multiTouch:
            break
        }

        primaryFinger = nil
        fingerMode = .idle
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let pencil = activePencil, touches.contains(pencil) {
            let (nx, ny) = normalizedVideoPoint(pencil.location(in: self))
            activePencil = nil
            onTouchInput?(TouchInputPacket(kind: .leftUp, normX: nx, normY: ny, isPencil: true))
        }
        cancelFingerTimers()
        if fingerMode == .dragging, let f = primaryFinger {
            let (nx, ny) = normalizedVideoPoint(f.location(in: self))
            onTouchInput?(TouchInputPacket(kind: .leftUp, normX: nx, normY: ny))
        }
        primaryFinger = nil
        fingerMode = .idle
    }

    // MARK: - 120Hz Natural Scroll Momentum

    private func startMomentumScroll(anchor: CGPoint) {
        let speed = hypot(scrollVelocity.x, scrollVelocity.y)
        guard speed > 140 else { return }
        momentumAnchorPoint = anchor
        let link = CADisplayLink(target: self, selector: #selector(stepMomentum(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    @objc private func stepMomentum(_ link: CADisplayLink) {
        let dt = CGFloat(max(0.004, min(0.02, link.targetTimestamp - link.timestamp)))
        // Smooth exponential decay matching macOS / iPadOS inertia feel.
        let decay = pow(0.06, dt)
        scrollVelocity.x *= decay
        scrollVelocity.y *= decay

        if hypot(scrollVelocity.x, scrollVelocity.y) < 35 {
            stopMomentumScroll()
            return
        }
        let dx = Float(scrollVelocity.x * dt * 1.8)
        let dy = Float(scrollVelocity.y * dt * 1.8)
        let (nx, ny) = normalizedVideoPoint(momentumAnchorPoint)
        onTouchInput?(TouchInputPacket(kind: .scroll, normX: nx, normY: ny, deltaX: dx, deltaY: dy, phase: 4))
    }

    private func stopMomentumScroll() {
        momentumLink?.invalidate()
        momentumLink = nil
        scrollVelocity = .zero
    }

    private func cancelFingerTimers() {
        holdToDragTimer?.cancel()
        holdToDragTimer = nil
        longPressRightClickTimer?.cancel()
        longPressRightClickTimer = nil
    }

    private func normalizedPencilPressure(_ touch: UITouch) -> Float {
        let maxF = touch.maximumPossibleForce
        guard maxF > 0 else { return 0.5 }
        return Float(max(0.05, min(1.0, touch.force / maxF)))
    }

    // MARK: - Hover, Pencil Pro Squeeze/Double-Tap & Multi-Touch Gestures

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed else { return }
        let pt = gesture.location(in: self)
        lastPencilHoverPoint = pt
        let (nx, ny) = normalizedVideoPoint(pt)
        onTouchInput?(TouchInputPacket(kind: .mouseMoved, normX: nx, normY: ny, pressure: 0, isPencil: true))
    }

    // Apple Pencil 2 double-tap -> Right click at current hover/last point
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        firePencilContextAction()
    }

    // Apple Pencil Pro Squeeze -> Right click at current hover/last point
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        if squeeze.phase == .ended {
            firePencilContextAction()
        }
    }

    private func firePencilContextAction() {
        let pt = lastPencilHoverPoint ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let (nx, ny) = normalizedVideoPoint(pt)
        hapticMedium.impactOccurred()
        showFeedbackRing(at: pt, color: .systemOrange)
        onTouchInput?(TouchInputPacket(kind: .rightClick, normX: nx, normY: ny, isPencil: true))
    }

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        let pt = gesture.location(in: self)
        let (nx, ny) = normalizedVideoPoint(pt)
        hapticLight.impactOccurred()
        showFeedbackRing(at: pt, color: .systemOrange)
        onTouchInput?(TouchInputPacket(kind: .rightClick, normX: nx, normY: ny))
    }

    @objc private func handleThreeFingerTap(_ gesture: UITapGestureRecognizer) {
        onToggleHUD?()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began {
            lastPinchScale = gesture.scale
            return
        }
        guard gesture.state == .changed else { return }
        let ratio = gesture.scale / max(0.01, lastPinchScale)
        if ratio > 1.12 || ratio < 0.89 {
            let pt = gesture.location(in: self)
            let (nx, ny) = normalizedVideoPoint(pt)
            let dir: Float = ratio > 1.0 ? 1.0 : -1.0
            onTouchInput?(TouchInputPacket(kind: .pinchZoom, normX: nx, normY: ny, deltaY: dir))
            lastPinchScale = gesture.scale
        }
    }

    @objc private func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
        let pt = gesture.location(in: self)
        if gesture.state == .began {
            stopMomentumScroll()
            lastTwoFingerPanPoint = pt
            return
        }
        guard gesture.state == .changed else { return }
        let dx = Float((pt.x - lastTwoFingerPanPoint.x) * 2.2)
        let dy = Float((pt.y - lastTwoFingerPanPoint.y) * 2.2)
        lastTwoFingerPanPoint = pt
        let (nx, ny) = normalizedVideoPoint(pt)
        onTouchInput?(TouchInputPacket(kind: .scroll, normX: nx, normY: ny, deltaX: dx, deltaY: dy, phase: 2))
    }

    @objc private func handleThreeFingerPan(_ gesture: UIPanGestureRecognizer) {
        let pt = gesture.location(in: self)
        if gesture.state == .began {
            threeFingerStartPoint = pt
            threeFingerTriggered = false
            return
        }
        guard gesture.state == .changed, !threeFingerTriggered else { return }
        let dx = pt.x - threeFingerStartPoint.x
        let dy = pt.y - threeFingerStartPoint.y
        if hypot(dx, dy) < 65 { return }

        threeFingerTriggered = true
        let (nx, ny) = normalizedVideoPoint(pt)
        if abs(dy) > abs(dx) && dy < 0 {
            hapticLight.impactOccurred()
            onTouchInput?(TouchInputPacket(kind: .missionControl, normX: nx, normY: ny))
        } else if abs(dx) > abs(dy) {
            hapticLight.impactOccurred()
            let kind: TouchEventKind = dx > 0 ? .switchSpaceLeft : .switchSpaceRight
            onTouchInput?(TouchInputPacket(kind: kind, normX: nx, normY: ny))
        }
    }
}

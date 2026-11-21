import UIKit

final class DisplayViewController: UIViewController {
    private let videoView = VideoDisplayView()
    private let touchOverlay = TouchOverlayView()
    private let server = USBServer()

    // OLED standby landing overlay
    private let standbyContainer = UIView()
    private let glowLayer = CAGradientLayer()
    private let pulseDot = UIView()
    private let waitingTitle = UILabel()
    private let waitingSubtitle = UILabel()
    private let specBadgeLabel = UILabel()

    // Floating Dynamic Pill HUD
    private let hudContainer = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let hudDot = UIView()
    private let hudLabel = UILabel()

    private var displayLink: CADisplayLink?
    private var statsTimer: Timer?
    private let statsLock = NSLock()
    private var receivedFrames = 0
    private var receivedBytes = 0
    private var currentConfig: StreamConfig?
    private var hudVisible = false
    private var hudHideWorkItem: DispatchWorkItem?
    private var lastErrorText: String?

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        UIApplication.shared.isIdleTimerDisabled = true

        setupVideoAndTouch()
        setupStandbyUI()
        setupFloatingHUD()
        setupProMotionDisplayLink()
        setupServer()
        startStatsTimer()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        glowLayer.frame = standbyContainer.bounds
    }

    deinit {
        displayLink?.invalidate()
        statsTimer?.invalidate()
        server.stop()
    }

    private func setupVideoAndTouch() {
        videoView.translatesAutoresizingMaskIntoConstraints = false
        touchOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoView)
        view.addSubview(touchOverlay)

        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            touchOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            touchOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            touchOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            touchOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        touchOverlay.onTouchInput = { [weak self] input in
            self?.server.sendTouch(input)
        }
        touchOverlay.onToggleHUD = { [weak self] in
            self?.toggleHUD()
        }
        videoView.onRequestKeyframe = { [weak self] in
            self?.server.requestKeyframe()
        }
        videoView.onDecodeError = { [weak self] msg in
            DispatchQueue.main.async {
                self?.lastErrorText = msg
            }
        }
    }

    private func setupStandbyUI() {
        standbyContainer.translatesAutoresizingMaskIntoConstraints = false
        standbyContainer.backgroundColor = .black
        standbyContainer.isUserInteractionEnabled = false
        view.addSubview(standbyContainer)
        NSLayoutConstraint.activate([
            standbyContainer.topAnchor.constraint(equalTo: view.topAnchor),
            standbyContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            standbyContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            standbyContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // Subtle OLED ambient radial gradient
        glowLayer.type = .radial
        glowLayer.colors = [
            UIColor.systemCyan.withAlphaComponent(0.16).cgColor,
            UIColor.systemBlue.withAlphaComponent(0.05).cgColor,
            UIColor.clear.cgColor
        ]
        glowLayer.startPoint = CGPoint(x: 0.5, y: 0.45)
        glowLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        standbyContainer.layer.addSublayer(glowLayer)

        // Device connection diagram
        let iconRow = UIStackView()
        iconRow.axis = .horizontal
        iconRow.alignment = .center
        iconRow.spacing = 22
        let symCfg = UIImage.SymbolConfiguration(pointSize: 38, weight: .light)
        let macImg = UIImageView(image: UIImage(systemName: "laptopcomputer", withConfiguration: symCfg))
        macImg.tintColor = .white.withAlphaComponent(0.85)
        let cableImg = UIImageView(image: UIImage(systemName: "bolt.horizontal.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)))
        cableImg.tintColor = .systemCyan
        let ipadImg = UIImageView(image: UIImage(systemName: "ipad.landscape", withConfiguration: symCfg))
        ipadImg.tintColor = .white
        iconRow.addArrangedSubview(macImg)
        iconRow.addArrangedSubview(cableImg)
        iconRow.addArrangedSubview(ipadImg)

        waitingTitle.text = "HyperDisplay"
        waitingTitle.font = .systemFont(ofSize: 34, weight: .bold)
        waitingTitle.textColor = .white

        // Status pill row
        let statusRow = UIStackView()
        statusRow.axis = .horizontal
        statusRow.alignment = .center
        statusRow.spacing = 8

        pulseDot.backgroundColor = .systemCyan
        pulseDot.layer.cornerRadius = 4.5
        pulseDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pulseDot.widthAnchor.constraint(equalToConstant: 9),
            pulseDot.heightAnchor.constraint(equalToConstant: 9)
        ])
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.25
        pulse.duration = 1.1
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulseDot.layer.add(pulse, forKey: "pulse")

        waitingSubtitle.text = "等待 Mac 通过 USB-C 线连接..."
        waitingSubtitle.font = .systemFont(ofSize: 16, weight: .medium)
        waitingSubtitle.textColor = UIColor.white.withAlphaComponent(0.75)

        statusRow.addArrangedSubview(pulseDot)
        statusRow.addArrangedSubview(waitingSubtitle)

        // Hardware capability badge
        let screen = UIScreen.main
        let w = Int(max(screen.nativeBounds.width, screen.nativeBounds.height).rounded())
        let h = Int(min(screen.nativeBounds.width, screen.nativeBounds.height).rounded())
        let fps = screen.maximumFramesPerSecond
        specBadgeLabel.text = "  \(w) × \(h) · \(fps)Hz ProMotion · USB 10Gbps Direct  "
        specBadgeLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        specBadgeLabel.textColor = .systemCyan
        specBadgeLabel.backgroundColor = UIColor.systemCyan.withAlphaComponent(0.12)
        specBadgeLabel.layer.cornerRadius = 12
        specBadgeLabel.clipsToBounds = true
        specBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        specBadgeLabel.heightAnchor.constraint(equalToConstant: 28).isActive = true

        // Gesture hints footer
        let hints = UILabel()
        hints.text = "单指滑=自然滚动 · 停顿拖=拖拽 · 长按/双指点=右键 · 三指滑=桌面/调度中心 · 三指轻点=状态栏 · Apple Pencil 悬停压感"
        hints.font = .systemFont(ofSize: 12, weight: .regular)
        hints.textColor = UIColor.white.withAlphaComponent(0.45)
        hints.textAlignment = .center
        hints.numberOfLines = 2
        hints.translatesAutoresizingMaskIntoConstraints = false

        let centerStack = UIStackView(arrangedSubviews: [iconRow, waitingTitle, statusRow, specBadgeLabel])
        centerStack.axis = .vertical
        centerStack.alignment = .center
        centerStack.spacing = 16
        centerStack.setCustomSpacing(8, after: waitingTitle)
        centerStack.translatesAutoresizingMaskIntoConstraints = false
        standbyContainer.addSubview(centerStack)
        standbyContainer.addSubview(hints)

        NSLayoutConstraint.activate([
            centerStack.centerXAnchor.constraint(equalTo: standbyContainer.centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: standbyContainer.centerYAnchor, constant: -16),
            hints.bottomAnchor.constraint(equalTo: standbyContainer.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            hints.leadingAnchor.constraint(equalTo: standbyContainer.leadingAnchor, constant: 32),
            hints.trailingAnchor.constraint(equalTo: standbyContainer.trailingAnchor, constant: -32)
        ])
    }

    private func setupFloatingHUD() {
        hudContainer.layer.cornerRadius = 16
        hudContainer.clipsToBounds = true
        hudContainer.alpha = 0
        hudContainer.layer.borderWidth = 0.8
        hudContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        hudContainer.translatesAutoresizingMaskIntoConstraints = false

        hudDot.backgroundColor = .systemGreen
        hudDot.layer.cornerRadius = 4
        hudDot.translatesAutoresizingMaskIntoConstraints = false

        hudLabel.font = .monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        hudLabel.textColor = .white
        hudLabel.text = "USB 已连接"
        hudLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [hudDot, hudLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        hudContainer.contentView.addSubview(stack)
        view.addSubview(hudContainer)

        NSLayoutConstraint.activate([
            hudDot.widthAnchor.constraint(equalToConstant: 8),
            hudDot.heightAnchor.constraint(equalToConstant: 8),
            hudContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            hudContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.topAnchor.constraint(equalTo: hudContainer.contentView.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: hudContainer.contentView.bottomAnchor, constant: -7),
            stack.leadingAnchor.constraint(equalTo: hudContainer.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: hudContainer.contentView.trailingAnchor, constant: -14)
        ])
    }

    private func setupProMotionDisplayLink() {
        let link = CADisplayLink(target: self, selector: #selector(onDisplayTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    @objc private func onDisplayTick() {}

    @objc private func handleWillEnterForeground() {
        videoView.reset()
        server.requestKeyframe()
    }

    private func setupServer() {
        server.onStatusChanged = { [weak self] text, connected in
            DispatchQueue.main.async {
                guard let self else { return }
                self.waitingSubtitle.text = text
                UIView.animate(withDuration: 0.25) {
                    self.standbyContainer.alpha = connected ? 0 : 1
                }
                if !connected {
                    self.videoView.reset()
                    self.hudVisible = false
                    UIView.animate(withDuration: 0.2) { self.hudContainer.alpha = 0 }
                } else {
                    self.lastErrorText = nil
                    self.showHUD(autoHide: true)
                }
            }
        }

        server.onConfigReceived = { [weak self] cfg in
            DispatchQueue.main.async {
                guard let self else { return }
                self.currentConfig = cfg
                self.touchOverlay.updateVideoAspect(pixelWidth: cfg.pixelWidth, pixelHeight: cfg.pixelHeight)
                self.videoView.reset()
                self.server.requestKeyframe()
                self.showHUD(autoHide: true)
            }
        }

        server.onVideoFrameReceived = { [weak self] header, payload in
            guard let self else { return }
            self.videoView.enqueueVideoFrame(header: header, payload: payload)
            self.statsLock.lock()
            self.receivedFrames += 1
            self.receivedBytes += payload.count
            self.statsLock.unlock()
        }

        server.start()
    }

    private func startStatsTimer() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.statsLock.lock()
            let f = self.receivedFrames
            let b = self.receivedBytes
            self.receivedFrames = 0
            self.receivedBytes = 0
            self.statsLock.unlock()

            if f > 0 {
                let mbps = Double(b) * 8.0 / 1_000_000.0
                let cfgText = self.currentConfig.map {
                    "\($0.pixelWidth)×\($0.pixelHeight) · \($0.codecMode.shortLabel)"
                } ?? "USB"
                let errSuffix = self.lastErrorText.map { " · ERR: \($0)" } ?? ""
                self.hudDot.backgroundColor = f >= 100 ? .systemGreen : .systemCyan
                self.hudLabel.text = String(format: "%d FPS · %.1f Mbps · %@%@", f, mbps, cfgText, errSuffix)
            }
        }
    }

    private func toggleHUD() {
        if hudVisible {
            hudHideWorkItem?.cancel()
            hudVisible = false
            UIView.animate(withDuration: 0.2) { self.hudContainer.alpha = 0 }
        } else {
            showHUD(autoHide: true)
        }
    }

    private func showHUD(autoHide: Bool) {
        hudHideWorkItem?.cancel()
        hudVisible = true
        UIView.animate(withDuration: 0.22) { self.hudContainer.alpha = 1 }
        if autoHide {
            scheduleHUDAutoHide()
        }
    }

    private func scheduleHUDAutoHide() {
        hudHideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hudVisible = false
            UIView.animate(withDuration: 0.35) { self.hudContainer.alpha = 0 }
        }
        hudHideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: item)
    }
}

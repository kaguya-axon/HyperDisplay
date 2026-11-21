import Foundation
import Combine
import CoreGraphics
import ApplicationServices
import AppKit

@MainActor
final class DisplayController: ObservableObject {
    @Published var connectionStatus: String = "等待通过 USB-C 连接 iPad Pro..."
    @Published var isStreaming: Bool = false
    @Published var connectedHello: ClientHello?
    @Published var usbDeviceCount: Int = 0

    // User-configurable parameters
    @Published var preferredCodecMode: CodecProfileMode = .hevc42210
    @Published var autoMatchDeviceCodec: Bool = true
    @Published var prioritizeSpeed: Bool = true
    @Published var targetFPS: Int = 120
    @Published var bitrateMbps: Int = 260
    @Published var scaleMultiplier: Double = 1.0

    // Live telemetry
    @Published var actualFPS: Double = 0
    @Published var actualMbps: Double = 0
    @Published var avgEncodeMs: Double = 0
    @Published var p50EncodeMs: Double = 0
    @Published var p95EncodeMs: Double = 0
    @Published var usbRttMs: Double = 0
    @Published var droppedFrames: UInt64 = 0
    @Published var fpsHistory: [Double] = []
    @Published var encodeHistory: [Double] = []
    @Published var activeCodecLabel: String = "-"
    @Published var activeResolutionLabel: String = "-"
    @Published var screenRecordingGranted: Bool = false
    @Published var accessibilityGranted: Bool = false
    @Published var logs: [String] = []

    private let usbClient = USBMuxClient()
    private let displayManager = VirtualDisplayManager()
    private let captureEngine = ScreenCaptureEngine()
    private let encoder = VideoEncoder()
    private let inputInjector = InputInjector()

    private var frameSeq: UInt32 = 0
    private let statsLock = NSLock()
    private var intervalFrames: Int = 0
    private var intervalBytes: Int = 0
    private var intervalEncodeSamples: [Double] = []
    private var latestDropped: UInt64 = 0

    private var statsTimer: Timer?
    private var pingTimer: Timer?
    private var controlListenFD: Int32 = -1
    private let controlQueue = DispatchQueue(label: "com.axonter.hyperdisplay.localcontrol")

    init() {
        refreshPermissions()
        wireCallbacks()
    }

    func startService() {
        refreshPermissions()
        usbClient.start()
        startTimers()
        startLocalControlServer()
        appendLog("HyperDisplay Mac 服务已启动 (USB: \(WireConstants.usbPort), LocalAPI: 127.0.0.1:\(WireConstants.localControlPort))")
    }

    func stopService() {
        statsTimer?.invalidate()
        pingTimer?.invalidate()
        if controlListenFD >= 0 {
            Darwin.close(controlListenFD)
            controlListenFD = -1
        }
        Task {
            await teardownPipeline()
        }
        usbClient.stop()
    }

    func refreshPermissions() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrusted()
    }

    func requestScreenRecordingPermission() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshPermissions()
        }
    }

    func requestAccessibilityPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshPermissions()
        }
    }

    func applySettingsAndRestartStream() {
        guard let hello = connectedHello else { return }
        Task {
            await startPipeline(for: hello)
        }
    }

    /// Reconfigures capture pixel format & VideoToolbox encoder WITHOUT destroying CGVirtualDisplay,
    /// so windows on the iPad screen stay put during live codec/speed/bitrate switches.
    func reconfigureEncoderInPlace() {
        guard isStreaming, let hello = connectedHello, displayManager.displayID != 0 else {
            applySettingsAndRestartStream()
            return
        }
        Task {
            let dispID = displayManager.displayID
            let targetW = displayManager.currentPixelWidth
            let targetH = displayManager.currentPixelHeight
            await captureEngine.stop()

            let chosenMode = encoder.configure(
                width: targetW,
                height: targetH,
                fps: targetFPS,
                bitrateMbps: bitrateMbps,
                preferredMode: preferredCodecMode,
                prioritizeSpeed: prioritizeSpeed
            )
            let config = StreamConfig(
                pixelWidth: targetW,
                pixelHeight: targetH,
                targetFPS: targetFPS,
                bitrateMbps: bitrateMbps,
                codecMode: chosenMode
            )
            if let cfgData = try? JSONEncoder().encode(config) {
                usbClient.enqueueControlPacket(type: .config, payload: cfgData)
            }
            usbClient.resetDroppedCount()
            resetStatsCounters()

            let useTenBit = (chosenMode == .hevc42210 || chosenMode == .hevc10)
            do {
                try await captureEngine.start(
                    displayID: dispID,
                    pixelWidth: targetW,
                    pixelHeight: targetH,
                    fps: targetFPS,
                    useTenBit: useTenBit
                )
                activeCodecLabel = chosenMode.shortLabel
                activeResolutionLabel = "\(targetW) × \(targetH) @ \(targetFPS)Hz"
                connectionStatus = "已连接 \(hello.chipLabel) — 10Gbps USB 有线输出中"
                encoder.requestKeyframe()
            } catch {
                appendLog("热切换编码器失败: \(error.localizedDescription)")
            }
        }
    }

    func updateLiveBitrate(_ mbps: Int) {
        bitrateMbps = mbps
        encoder.updateBitrate(mbps)
    }

    func applyPreset(codec: CodecProfileMode, bitrate: Int, fps: Int, speed: Bool) {
        autoMatchDeviceCodec = false
        let fpsChanged = (targetFPS != fps)
        preferredCodecMode = codec
        bitrateMbps = bitrate
        targetFPS = fps
        prioritizeSpeed = speed
        if fpsChanged {
            applySettingsAndRestartStream()
        } else {
            reconfigureEncoderInPlace()
        }
    }

    func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func resetStatsCounters() {
        statsLock.lock()
        intervalFrames = 0
        intervalBytes = 0
        intervalEncodeSamples.removeAll(keepingCapacity: true)
        latestDropped = 0
        statsLock.unlock()
        droppedFrames = 0
    }

    private func wireCallbacks() {
        usbClient.onLog = { [weak self] msg in
            Task { @MainActor in self?.appendLog(msg) }
        }
        usbClient.onDevicesChanged = { [weak self] devs in
            Task { @MainActor in
                self?.usbDeviceCount = devs.count
                if self?.isStreaming == false {
                    self?.connectionStatus = devs.isEmpty
                        ? "未检测到 USB-C 连接的 iPad"
                        : "已检测到 \(devs.count) 台 USB 设备，请在 iPad 打开 HyperDisplay"
                }
            }
        }
        usbClient.onConnected = { [weak self] dev in
            Task { @MainActor in
                self?.connectionStatus = "USB 隧道已打通 (#\(dev.deviceID))，等待 iPad 握手..."
            }
        }
        usbClient.onDisconnected = { [weak self] reason in
            Task { @MainActor in
                self?.connectionStatus = reason
                self?.connectedHello = nil
                await self?.teardownPipeline()
            }
        }
        usbClient.onPacketReceived = { [weak self] header, payload in
            self?.handleIncomingPacket(header: header, payload: payload)
        }
        usbClient.onDroppedFrameNeedsKeyframe = { [weak self] in
            self?.encoder.requestKeyframe()
        }

        captureEngine.onFrame = { [weak self] pixelBuffer, captureTs in
            self?.encoder.encode(pixelBuffer: pixelBuffer, captureTimestampNs: captureTs)
        }
        captureEngine.onError = { [weak self] err in
            Task { @MainActor in self?.appendLog(err) }
        }

        encoder.onLog = { [weak self] msg in
            Task { @MainActor in self?.appendLog(msg) }
        }
        encoder.onEncodedFrame = { [weak self] payload, isKeyframe, captureTs, encodeMs in
            guard let self else { return }
            self.frameSeq &+= 1
            var flags: PacketFlags = []
            if isKeyframe { flags.insert(.keyframe) }
            if self.encoder.activeMode == .hevc42210 {
                flags.insert(.tenBit)
                flags.insert(.chroma422)
            } else if self.encoder.activeMode == .hevc10 {
                flags.insert(.tenBit)
            }
            let dropped = self.usbClient.enqueueVideoFrame(
                flags: flags,
                timestampNs: captureTs,
                payload: payload,
                sequence: self.frameSeq
            )
            self.statsLock.lock()
            self.intervalFrames += 1
            self.intervalBytes += payload.count
            self.intervalEncodeSamples.append(encodeMs)
            self.latestDropped = dropped
            self.statsLock.unlock()
        }
    }

    private nonisolated func handleIncomingPacket(header: PacketHeader, payload: Data) {
        switch header.type {
        case .hello:
            if let hello = try? JSONDecoder().decode(ClientHello.self, from: payload) {
                Task { @MainActor in
                    self.connectedHello = hello
                    if self.autoMatchDeviceCodec {
                        self.preferredCodecMode = hello.supportsHEVC42210 ? .hevc42210 : .hevc10
                    }
                    self.targetFPS = hello.maxRefreshRate >= 120 ? 120 : 60
                    self.appendLog("已握手: \(hello.chipLabel) (\(hello.modelIdentifier)) \(hello.nativePixelWidth)x\(hello.nativePixelHeight) @ \(hello.maxRefreshRate)Hz")
                    await self.startPipeline(for: hello)
                }
            }
        case .touchInput:
            if let touch = TouchInputPacket.decode(payload) {
                inputInjector.handle(touch)
            }
        case .keyframeRequest:
            encoder.requestKeyframe()
        case .pong:
            let now = MonotonicClock.nowNs()
            if now >= header.timestampNs {
                let rtt = Double(now - header.timestampNs) / 1_000_000.0
                Task { @MainActor in
                    self.usbRttMs = rtt
                }
            }
        default:
            break
        }
    }

    private func startPipeline(for hello: ClientHello) async {
        await teardownPipeline()
        refreshPermissions()

        guard screenRecordingGranted else {
            connectionStatus = "缺少「屏幕录制」权限，请先授权后点击重新连接"
            appendLog("缺少屏幕录制权限，无法启动 ScreenCaptureKit")
            return
        }

        let targetW = max(640, (hello.nativePixelWidth / 2) * 2)
        let targetH = max(480, (hello.nativePixelHeight / 2) * 2)

        guard let dispID = displayManager.createDisplay(
            name: "HyperDisplay \(hello.chipLabel)",
            pixelWidth: targetW,
            pixelHeight: targetH,
            scaleFactor: scaleMultiplier,
            refreshRate: Double(targetFPS)
        ) else {
            connectionStatus = "创建虚拟显示器失败"
            appendLog("CGVirtualDisplay 创建失败")
            return
        }

        inputInjector.setDisplayID(dispID)
        try? await Task.sleep(nanoseconds: 350_000_000)

        let chosenMode = encoder.configure(
            width: targetW,
            height: targetH,
            fps: targetFPS,
            bitrateMbps: bitrateMbps,
            preferredMode: preferredCodecMode,
            prioritizeSpeed: prioritizeSpeed
        )

        let config = StreamConfig(
            pixelWidth: targetW,
            pixelHeight: targetH,
            targetFPS: targetFPS,
            bitrateMbps: bitrateMbps,
            codecMode: chosenMode
        )
        if let cfgData = try? JSONEncoder().encode(config) {
            usbClient.enqueueControlPacket(type: .config, payload: cfgData)
        }

        usbClient.resetDroppedCount()
        resetStatsCounters()
        let useTenBit = (chosenMode == .hevc42210 || chosenMode == .hevc10)

        do {
            try await captureEngine.start(
                displayID: dispID,
                pixelWidth: targetW,
                pixelHeight: targetH,
                fps: targetFPS,
                useTenBit: useTenBit
            )
            isStreaming = true
            activeCodecLabel = chosenMode.shortLabel
            activeResolutionLabel = "\(targetW) × \(targetH) @ \(targetFPS)Hz"
            connectionStatus = "已连接 \(hello.chipLabel) — 10Gbps USB 有线输出中"
            encoder.requestKeyframe()
        } catch {
            appendLog("启动截屏失败: \(error.localizedDescription)")
            connectionStatus = "截屏启动失败: \(error.localizedDescription)"
            displayManager.destroyDisplay()
        }
    }

    private func teardownPipeline() async {
        isStreaming = false
        await captureEngine.stop()
        encoder.invalidate()
        displayManager.destroyDisplay()
        inputInjector.setDisplayID(0)
        actualFPS = 0
        actualMbps = 0
        avgEncodeMs = 0
        p50EncodeMs = 0
        p95EncodeMs = 0
    }

    private func startTimers() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.statsLock.lock()
                let f = self.intervalFrames
                let b = self.intervalBytes
                let samples = self.intervalEncodeSamples
                let d = self.latestDropped
                self.intervalFrames = 0
                self.intervalBytes = 0
                self.intervalEncodeSamples.removeAll(keepingCapacity: true)
                self.statsLock.unlock()

                self.actualFPS = Double(f)
                self.actualMbps = Double(b) * 8.0 / 1_000_000.0
                if !samples.isEmpty {
                    let sorted = samples.sorted()
                    let avg = sorted.reduce(0, +) / Double(sorted.count)
                    let p50 = sorted[sorted.count / 2]
                    let p95Idx = min(sorted.count - 1, Int(Double(sorted.count) * 0.95))
                    self.avgEncodeMs = avg
                    self.p50EncodeMs = p50
                    self.p95EncodeMs = sorted[p95Idx]
                } else {
                    self.avgEncodeMs = 0
                    self.p50EncodeMs = 0
                    self.p95EncodeMs = 0
                }
                self.droppedFrames = d
                if self.isStreaming {
                    self.fpsHistory.append(self.actualFPS)
                    self.encodeHistory.append(self.p50EncodeMs)
                    if self.fpsHistory.count > 36 { self.fpsHistory.removeFirst() }
                    if self.encodeHistory.count > 36 { self.encodeHistory.removeFirst() }
                } else if !self.fpsHistory.isEmpty {
                    self.fpsHistory.removeAll()
                    self.encodeHistory.removeAll()
                }
            }
        }

        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isStreaming else { return }
                self.usbClient.enqueueControlPacket(type: .ping, payload: Data())
            }
        }
    }

    // Localhost-only telemetry & benchmark control server (127.0.0.1:24121)
    private func startLocalControlServer() {
        controlQueue.async { [weak self] in
            guard let self else { return }
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = WireConstants.localControlPort.bigEndian
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard ok == 0, Darwin.listen(fd, 8) == 0 else {
                Darwin.close(fd)
                return
            }
            self.controlListenFD = fd

            while self.controlListenFD == fd {
                var caddr = sockaddr_in()
                var clen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let cfd = withUnsafeMutablePointer(to: &caddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.accept(fd, $0, &clen)
                    }
                }
                if cfd < 0 { break }
                self.handleControlClient(cfd)
                Darwin.close(cfd)
            }
        }
    }

    private nonisolated func handleControlClient(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = Darwin.recv(fd, &buf, buf.count - 1, 0)
        guard n > 0 else { return }
        let cmd = String(decoding: buf.prefix(n), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        let sema = DispatchSemaphore(value: 0)
        var responseStr = "{}\n"

        Task { @MainActor in
            if cmd.hasPrefix("SET ") {
                let tokens = cmd.dropFirst(4).split(separator: " ")
                var needReconfig = false
                for tok in tokens {
                    let kv = tok.split(separator: "=", maxSplits: 1)
                    guard kv.count == 2 else { continue }
                    let k = String(kv[0]), v = String(kv[1])
                    switch k {
                    case "codec":
                        if let m = CodecProfileMode.fromCLIKey(v), m != self.preferredCodecMode {
                            self.autoMatchDeviceCodec = false
                            self.preferredCodecMode = m
                            needReconfig = true
                        }
                    case "speed":
                        let b = (v == "1" || v.lowercased() == "true")
                        if b != self.prioritizeSpeed {
                            self.prioritizeSpeed = b
                            needReconfig = true
                        }
                    case "bitrate":
                        if let mbps = Int(v), mbps >= 20, mbps <= 1000 {
                            self.bitrateMbps = mbps
                            if !needReconfig {
                                self.encoder.updateBitrate(mbps)
                            }
                        }
                    case "resetdrop":
                        if v == "1" {
                            self.usbClient.resetDroppedCount()
                            self.resetStatsCounters()
                        }
                    default:
                        break
                    }
                }
                if needReconfig {
                    self.reconfigureEncoderInPlace()
                }
            }

            let dict: [String: Any] = [
                "isStreaming": self.isStreaming,
                "actualFPS": self.actualFPS,
                "actualMbps": self.actualMbps,
                "encodeAvgMs": self.avgEncodeMs,
                "encodeP50Ms": self.p50EncodeMs,
                "encodeP95Ms": self.p95EncodeMs,
                "usbRttMs": self.usbRttMs,
                "droppedFrames": self.droppedFrames,
                "codec": self.preferredCodecMode.cliKey,
                "activeCodec": self.activeCodecLabel,
                "bitrateMbps": self.bitrateMbps,
                "prioritizeSpeed": self.prioritizeSpeed,
                "targetFPS": self.targetFPS,
                "resolution": self.activeResolutionLabel
            ]
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let s = String(data: data, encoding: .utf8) {
                responseStr = s + "\n"
            }
            sema.signal()
        }

        _ = sema.wait(timeout: .now() + 2.0)
        if let data = responseStr.data(using: .utf8) {
            _ = SocketIO.sendAll(fd: fd, data: data)
        }
    }

    private func appendLog(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append("[\(formatter.string(from: Date()))] \(text)")
        if logs.count > 40 {
            logs.removeFirst(logs.count - 40)
        }
    }
}

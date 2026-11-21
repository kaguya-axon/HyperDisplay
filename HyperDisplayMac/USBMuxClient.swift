import Foundation

struct AttachedUSBDevice: Equatable, Identifiable {
    let deviceID: Int
    let serialNumber: String
    let productID: Int

    var id: Int { deviceID }
}

final class USBMuxClient {
    var onLog: ((String) -> Void)?
    var onDevicesChanged: (([AttachedUSBDevice]) -> Void)?
    var onConnected: ((AttachedUSBDevice) -> Void)?
    var onDisconnected: ((String) -> Void)?
    var onPacketReceived: ((PacketHeader, Data) -> Void)?
    var onDroppedFrameNeedsKeyframe: (() -> Void)?

    private let listenerQueue = DispatchQueue(label: "com.axonter.hyperdisplay.usbmux.listen")
    private let connectQueue = DispatchQueue(label: "com.axonter.hyperdisplay.usbmux.connect")
    private let readQueue = DispatchQueue(label: "com.axonter.hyperdisplay.usbmux.read")
    private let sendQueue = DispatchQueue(label: "com.axonter.hyperdisplay.usbmux.send", qos: .userInteractive)

    private var listenFD: Int32 = -1
    private var activeFD: Int32 = -1
    private var activeDevice: AttachedUSBDevice?
    private let devicesLock = NSLock()
    private var attachedDevices: [Int: AttachedUSBDevice] = [:]
    private var isRunning = false
    private var connectLoopWorkItem: DispatchWorkItem?
    private var tagCounter: UInt32 = 1

    // Zero-queueing latest-frame slot so USB never builds up latency.
    private let frameLock = NSLock()
    private var pendingKeyframe: (PacketHeader, Data)?
    private var pendingDeltaFrame: (PacketHeader, Data)?
    private var pendingControlPackets: [(PacketHeader, Data)] = []
    private var waitingForRecoveryKeyframe = false
    private let sendSignal = DispatchSemaphore(value: 0)
    private var droppedFrameCount: UInt64 = 0

    func start() {
        guard !isRunning else { return }
        isRunning = true
        listenerQueue.async { [weak self] in
            self?.runListenLoop()
        }
        sendQueue.async { [weak self] in
            self?.runSendLoop()
        }
    }

    func stop() {
        isRunning = false
        closeActiveConnection(reason: "已手动停止")
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
        sendSignal.signal()
    }

    func enqueueControlPacket(type: PacketType, flags: PacketFlags = [], payload: Data, sequence: UInt32 = 0) {
        let header = PacketHeader(
            type: type,
            flags: flags,
            timestampNs: MonotonicClock.nowNs(),
            payloadLength: UInt32(payload.count),
            sequence: sequence
        )
        frameLock.lock()
        pendingControlPackets.append((header, payload))
        frameLock.unlock()
        sendSignal.signal()
    }

    /// Latest-frame-wins queueing with HEVC reference-chain protection:
    /// If a delta frame is dropped due to backpressure, skip orphan delta frames and request an immediate IDR.
    func enqueueVideoFrame(flags: PacketFlags, timestampNs: UInt64, payload: Data, sequence: UInt32) -> UInt64 {
        let header = PacketHeader(
            type: .videoFrame,
            flags: flags,
            timestampNs: timestampNs,
            payloadLength: UInt32(payload.count),
            sequence: sequence
        )
        var triggerIDR = false
        frameLock.lock()
        if flags.contains(.keyframe) {
            if pendingKeyframe != nil { droppedFrameCount += 1 }
            pendingKeyframe = (header, payload)
            pendingDeltaFrame = nil
            waitingForRecoveryKeyframe = false
        } else if waitingForRecoveryKeyframe {
            // Do not send orphan P-frames whose reference was already dropped.
            droppedFrameCount += 1
        } else if pendingDeltaFrame != nil {
            // Backpressure hit: drop stale delta and ask encoder for an instant recovery IDR.
            droppedFrameCount += 1
            pendingDeltaFrame = nil
            waitingForRecoveryKeyframe = true
            triggerIDR = true
        } else {
            pendingDeltaFrame = (header, payload)
        }
        let dropped = droppedFrameCount
        frameLock.unlock()

        if triggerIDR {
            onDroppedFrameNeedsKeyframe?()
        } else if !waitingForRecoveryKeyframe || flags.contains(.keyframe) {
            sendSignal.signal()
        }
        return dropped
    }

    func resetDroppedCount() {
        frameLock.lock()
        droppedFrameCount = 0
        waitingForRecoveryKeyframe = false
        frameLock.unlock()
    }

    private func openUnixSocket() -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = "/var/run/usbmuxd"
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        _ = path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
                strncpy(ptr, cstr, maxPathLen)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, len)
            }
        }
        if res != 0 {
            Darwin.close(fd)
            return -1
        }
        return fd
    }

    private func sendMuxPlist(fd: Int32, dict: [String: Any]) -> Bool {
        guard let plistData = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else {
            return false
        }
        var header = Data(capacity: 16)
        var totalLen = UInt32(16 + plistData.count).littleEndian
        var version = UInt32(1).littleEndian
        var message = UInt32(8).littleEndian // MESSAGE_PLIST
        tagCounter &+= 1
        var tag = tagCounter.littleEndian

        withUnsafeBytes(of: &totalLen) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &version) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &message) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &tag) { header.append(contentsOf: $0) }

        var full = Data(capacity: 16 + plistData.count)
        full.append(header)
        full.append(plistData)
        return SocketIO.sendAll(fd: fd, data: full)
    }

    private func readMuxPlist(fd: Int32) -> [String: Any]? {
        guard let hdr = SocketIO.recvExact(fd: fd, count: 16) else { return nil }
        let totalLen = hdr.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) }
        guard totalLen >= 16, totalLen < 4 * 1024 * 1024 else { return nil }
        guard let body = SocketIO.recvExact(fd: fd, count: Int(totalLen - 16)) else { return nil }
        guard let obj = try? PropertyListSerialization.propertyList(from: body, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private func runListenLoop() {
        while isRunning {
            let fd = openUnixSocket()
            if fd < 0 {
                onLog?("无法连接 /var/run/usbmuxd，1 秒后重试")
                Thread.sleep(forTimeInterval: 1.0)
                continue
            }
            listenFD = fd

            let listenReq: [String: Any] = [
                "MessageType": "Listen",
                "ClientVersionString": "HyperDisplayMac",
                "ProgName": "HyperDisplayMac"
            ]
            guard sendMuxPlist(fd: fd, dict: listenReq) else {
                Darwin.close(fd)
                listenFD = -1
                Thread.sleep(forTimeInterval: 1.0)
                continue
            }

            onLog?("已连接 usbmuxd，正在监听 USB 设备...")

            while isRunning {
                guard let msg = readMuxPlist(fd: fd) else { break }
                guard let msgType = msg["MessageType"] as? String else { continue }
                if msgType == "Attached",
                   let deviceID = msg["DeviceID"] as? Int,
                   let props = msg["Properties"] as? [String: Any] {
                    let connType = props["ConnectionType"] as? String ?? ""
                    if connType == "USB" {
                        let serial = props["SerialNumber"] as? String ?? ""
                        let productID = props["ProductID"] as? Int ?? 0
                        let dev = AttachedUSBDevice(deviceID: deviceID, serialNumber: serial, productID: productID)
                        devicesLock.lock()
                        attachedDevices[deviceID] = dev
                        let list = Array(attachedDevices.values).sorted { $0.deviceID < $1.deviceID }
                        devicesLock.unlock()
                        onDevicesChanged?(list)
                        onLog?("检测到 USB 设备 #\(deviceID) (PID: 0x\(String(productID, radix: 16)))")
                        scheduleConnectAttempt()
                    }
                } else if msgType == "Detached", let deviceID = msg["DeviceID"] as? Int {
                    devicesLock.lock()
                    attachedDevices.removeValue(forKey: deviceID)
                    let list = Array(attachedDevices.values).sorted { $0.deviceID < $1.deviceID }
                    devicesLock.unlock()
                    onDevicesChanged?(list)
                    if activeDevice?.deviceID == deviceID {
                        closeActiveConnection(reason: "USB 设备已断开")
                    }
                }
            }

            Darwin.close(fd)
            listenFD = -1
            if isRunning {
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
    }

    private func scheduleConnectAttempt() {
        connectQueue.async { [weak self] in
            guard let self, self.isRunning, self.activeFD < 0 else { return }
            self.connectLoopWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.attemptConnectToAnyDevice()
            }
            self.connectLoopWorkItem = item
            self.connectQueue.asyncAfter(deadline: .now() + 0.25, execute: item)
        }
    }

    private func attemptConnectToAnyDevice() {
        guard isRunning, activeFD < 0 else { return }
        devicesLock.lock()
        let candidates = Array(attachedDevices.values).sorted { $0.deviceID < $1.deviceID }
        devicesLock.unlock()
        guard !candidates.isEmpty else { return }

        // Network byte order for usbmuxd PortNumber!
        let portBE = Int(WireConstants.usbPort.bigEndian)

        for dev in candidates {
            let fd = openUnixSocket()
            if fd < 0 { continue }

            let connectReq: [String: Any] = [
                "MessageType": "Connect",
                "DeviceID": dev.deviceID,
                "PortNumber": portBE,
                "ClientVersionString": "HyperDisplayMac",
                "ProgName": "HyperDisplayMac"
            ]
            if sendMuxPlist(fd: fd, dict: connectReq),
               let resp = readMuxPlist(fd: fd),
               (resp["MessageType"] as? String) == "Result",
               (resp["Number"] as? Int) == 0 {
                SocketIO.configureLowLatencySocket(fd)
                activeFD = fd
                activeDevice = dev
                onLog?("已通过 USB 隧道连接设备 #\(dev.deviceID) 端口 \(WireConstants.usbPort)")
                onConnected?(dev)
                readQueue.async { [weak self] in
                    self?.runReadLoop(fd: fd)
                }
                return
            } else {
                Darwin.close(fd)
            }
        }

        // iPad app may not be open yet; keep polling gently.
        if isRunning && activeFD < 0 {
            let item = DispatchWorkItem { [weak self] in
                self?.attemptConnectToAnyDevice()
            }
            connectLoopWorkItem = item
            connectQueue.asyncAfter(deadline: .now() + 1.0, execute: item)
        }
    }

    private func runReadLoop(fd: Int32) {
        while isRunning && activeFD == fd {
            guard let hdrData = SocketIO.recvExact(fd: fd, count: WireConstants.headerSize),
                  let hdr = PacketHeader.decode(hdrData) else {
                break
            }
            guard hdr.payloadLength <= 16 * 1024 * 1024 else { break }
            guard let payload = SocketIO.recvExact(fd: fd, count: Int(hdr.payloadLength)) else {
                break
            }
            onPacketReceived?(hdr, payload)
        }

        if activeFD == fd {
            closeActiveConnection(reason: "iPad 端连接已关闭，等待重连...")
            scheduleConnectAttempt()
        }
    }

    private func runSendLoop() {
        while isRunning {
            sendSignal.wait()
            if !isRunning { break }

            while true {
                let fd = activeFD
                if fd < 0 {
                    frameLock.lock()
                    pendingControlPackets.removeAll()
                    pendingKeyframe = nil
                    pendingDeltaFrame = nil
                    frameLock.unlock()
                    break
                }

                var nextPacket: (PacketHeader, Data)?
                frameLock.lock()
                if !pendingControlPackets.isEmpty {
                    nextPacket = pendingControlPackets.removeFirst()
                } else if let kf = pendingKeyframe {
                    nextPacket = kf
                    pendingKeyframe = nil
                } else if let df = pendingDeltaFrame {
                    nextPacket = df
                    pendingDeltaFrame = nil
                }
                frameLock.unlock()

                guard let (header, payload) = nextPacket else { break }
                var packet = Data(capacity: WireConstants.headerSize + payload.count)
                packet.append(header.encode())
                packet.append(payload)

                if !SocketIO.sendAll(fd: fd, data: packet) {
                    closeActiveConnection(reason: "USB 写入中断，正在重连...")
                    scheduleConnectAttempt()
                    break
                }
            }
        }
    }

    private func closeActiveConnection(reason: String) {
        let fd = activeFD
        if fd >= 0 {
            activeFD = -1
            activeDevice = nil
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            onDisconnected?(reason)
        }
    }
}

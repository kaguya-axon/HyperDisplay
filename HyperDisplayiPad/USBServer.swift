import Foundation
import UIKit

final class USBServer {
    var onStatusChanged: ((String, Bool) -> Void)?
    var onConfigReceived: ((StreamConfig) -> Void)?
    var onVideoFrameReceived: ((PacketHeader, Data) -> Void)?

    private let acceptQueue = DispatchQueue(label: "com.axonter.hyperdisplay.ipad.accept")
    private let readQueue = DispatchQueue(label: "com.axonter.hyperdisplay.ipad.read", qos: .userInteractive)
    private let sendQueue = DispatchQueue(label: "com.axonter.hyperdisplay.ipad.send", qos: .userInteractive)

    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var isRunning = false
    private var seq: UInt32 = 0

    func start() {
        guard !isRunning else { return }
        isRunning = true
        acceptQueue.async { [weak self] in
            self?.runAcceptLoop()
        }
    }

    func stop() {
        isRunning = false
        closeClient()
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
    }

    func sendTouch(_ touch: TouchInputPacket) {
        sendPacket(type: .touchInput, payload: touch.encode())
    }

    func requestKeyframe() {
        sendPacket(type: .keyframeRequest, payload: Data())
    }

    private func sendPacket(type: PacketType, flags: PacketFlags = [], timestampNs: UInt64 = MonotonicClock.nowNs(), payload: Data) {
        sendQueue.async { [weak self] in
            guard let self, self.clientFD >= 0 else { return }
            self.seq &+= 1
            let header = PacketHeader(
                type: type,
                flags: flags,
                timestampNs: timestampNs,
                payloadLength: UInt32(payload.count),
                sequence: self.seq
            )
            var out = Data(capacity: WireConstants.headerSize + payload.count)
            out.append(header.encode())
            out.append(payload)
            if !SocketIO.sendAll(fd: self.clientFD, data: out) {
                self.closeClient()
            }
        }
    }

    private func runAcceptLoop() {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            onStatusChanged?("创建监听 Socket 失败", false)
            return
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = WireConstants.usbPort.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0, Darwin.listen(fd, 4) == 0 else {
            Darwin.close(fd)
            onStatusChanged?("绑定端口 \(WireConstants.usbPort) 失败 (errno=\(errno))", false)
            return
        }

        listenFD = fd
        onStatusChanged?("等待 Mac 通过 USB-C 线连接 (端口 \(WireConstants.usbPort))...", false)

        while isRunning {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let accepted = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(fd, $0, &clientLen)
                }
            }
            if accepted < 0 {
                if errno == EINTR { continue }
                break
            }

            closeClient()
            SocketIO.configureLowLatencySocket(accepted)
            clientFD = accepted
            onStatusChanged?("已连接 Mac (USB 隧道)", true)

            sendHelloPacket()
            runReadLoop(fd: accepted)
        }
    }

    private func sendHelloPacket() {
        let hello = makeClientHello()
        if let data = try? JSONEncoder().encode(hello) {
            sendPacket(type: .hello, payload: data)
        }
    }

    private func makeClientHello() -> ClientHello {
        var sysInfo = utsname()
        uname(&sysInfo)
        let model = withUnsafePointer(to: &sysInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }

        var nativeW = 2420
        var nativeH = 1668
        var nativeScale = 2.0
        var maxFPS = 120
        var deviceName = "iPad Pro"

        DispatchQueue.main.sync {
            let screen = UIScreen.main
            let b = screen.nativeBounds
            // Always report landscape dimensions (width > height).
            nativeW = Int(max(b.width, b.height).rounded())
            nativeH = Int(min(b.width, b.height).rounded())
            nativeScale = Double(screen.nativeScale)
            maxFPS = screen.maximumFramesPerSecond
            deviceName = UIDevice.current.name
        }

        // M4 iPad Pro (iPad16,3 / 16,4 / 16,5 / 16,6) and newer support hardware HEVC 4:2:2 10-bit decode.
        // M1 (iPad13,*) and M2 (iPad14,*) default to HEVC Main10 4:2:0 10-bit hardware decode.
        let supports42210 = isM4OrNewer(modelIdentifier: model)

        return ClientHello(
            modelIdentifier: model,
            deviceName: deviceName,
            nativePixelWidth: nativeW,
            nativePixelHeight: nativeH,
            nativeScale: nativeScale,
            maxRefreshRate: maxFPS,
            supportsHEVC42210: supports42210
        )
    }

    private func isM4OrNewer(modelIdentifier: String) -> Bool {
        guard modelIdentifier.hasPrefix("iPad") else { return false }
        let suffix = modelIdentifier.dropFirst(4)
        let majorStr = suffix.split(separator: ",").first ?? ""
        if let major = Int(majorStr) {
            return major >= 16
        }
        return false
    }

    private func runReadLoop(fd: Int32) {
        readQueue.sync {
            while isRunning && clientFD == fd {
                guard let hdrData = SocketIO.recvExact(fd: fd, count: WireConstants.headerSize),
                      let hdr = PacketHeader.decode(hdrData) else {
                    break
                }
                guard hdr.payloadLength <= 16 * 1024 * 1024 else { break }
                guard let payload = SocketIO.recvExact(fd: fd, count: Int(hdr.payloadLength)) else {
                    break
                }

                switch hdr.type {
                case .videoFrame:
                    onVideoFrameReceived?(hdr, payload)
                case .config:
                    if let cfg = try? JSONDecoder().decode(StreamConfig.self, from: payload) {
                        onConfigReceived?(cfg)
                    }
                case .ping:
                    // Echo timestamp back immediately for accurate USB RTT measurement.
                    sendPacket(type: .pong, timestampNs: hdr.timestampNs, payload: Data())
                default:
                    break
                }
            }
        }

        if clientFD == fd {
            closeClient()
            onStatusChanged?("Mac 已断开，等待 USB-C 重连...", false)
        }
    }

    private func closeClient() {
        let fd = clientFD
        if fd >= 0 {
            clientFD = -1
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }
}

import Foundation

public enum WireConstants {
    public static let magic: UInt32 = 0x48595044 // "HYPD"
    public static let usbPort: UInt16 = 24120
    public static let localControlPort: UInt16 = 24121
    public static let headerSize: Int = 24
}

public enum PacketType: UInt8, Sendable {
    case hello = 1
    case config = 2
    case videoFrame = 3
    case touchInput = 4
    case ping = 5
    case pong = 6
    case keyframeRequest = 7
}

public struct PacketFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let keyframe = PacketFlags(rawValue: 1 << 0)
    public static let tenBit = PacketFlags(rawValue: 1 << 1)
    public static let chroma422 = PacketFlags(rawValue: 1 << 2)
}

public enum CodecProfileMode: UInt8, CaseIterable, Identifiable, Codable, Sendable {
    case hevc42210 = 1 // M4 iPad Pro: HEVC 4:2:2 10-bit
    case hevc10 = 2    // M1/M2/M4 iPad Pro: HEVC 4:2:0 10-bit
    case hevc8 = 3     // Universal 8-bit HEVC

    public var id: UInt8 { rawValue }

    public var displayName: String {
        switch self {
        case .hevc42210: return "HEVC 4:2:2 10-bit (M4 极致锐利)"
        case .hevc10: return "HEVC 4:2:0 10-bit (M1/M4 通用)"
        case .hevc8: return "HEVC 8-bit (最低延迟/兼容)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .hevc42210: return "HEVC 4:2:2 10b"
        case .hevc10: return "HEVC 4:2:0 10b"
        case .hevc8: return "HEVC 8b"
        }
    }

    public var cliKey: String {
        switch self {
        case .hevc42210: return "hevc42210"
        case .hevc10: return "hevc10"
        case .hevc8: return "hevc8"
        }
    }

    public static func fromCLIKey(_ key: String) -> CodecProfileMode? {
        switch key.lowercased() {
        case "hevc42210", "422": return .hevc42210
        case "hevc10", "10bit": return .hevc10
        case "hevc8", "8bit": return .hevc8
        default: return nil
        }
    }
}

public struct ClientHello: Codable, Sendable {
    public var modelIdentifier: String
    public var deviceName: String
    public var nativePixelWidth: Int
    public var nativePixelHeight: Int
    public var nativeScale: Double
    public var maxRefreshRate: Int
    public var supportsHEVC42210: Bool

    public init(
        modelIdentifier: String,
        deviceName: String,
        nativePixelWidth: Int,
        nativePixelHeight: Int,
        nativeScale: Double,
        maxRefreshRate: Int,
        supportsHEVC42210: Bool
    ) {
        self.modelIdentifier = modelIdentifier
        self.deviceName = deviceName
        self.nativePixelWidth = nativePixelWidth
        self.nativePixelHeight = nativePixelHeight
        self.nativeScale = nativeScale
        self.maxRefreshRate = maxRefreshRate
        self.supportsHEVC42210 = supportsHEVC42210
    }

    public var chipLabel: String {
        if modelIdentifier.hasPrefix("iPad16,") { return "M4 iPad Pro" }
        if modelIdentifier.hasPrefix("iPad14,") { return "M2 iPad Pro" }
        if modelIdentifier.hasPrefix("iPad13,") { return "M1 iPad Pro" }
        return modelIdentifier
    }
}

public struct StreamConfig: Codable, Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var targetFPS: Int
    public var bitrateMbps: Int
    public var codecMode: CodecProfileMode

    public init(pixelWidth: Int, pixelHeight: Int, targetFPS: Int, bitrateMbps: Int, codecMode: CodecProfileMode) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.targetFPS = targetFPS
        self.bitrateMbps = bitrateMbps
        self.codecMode = codecMode
    }
}

public enum TouchEventKind: UInt8, Codable, Sendable {
    case leftDown = 1
    case leftDragged = 2
    case leftUp = 3
    case mouseMoved = 4
    case rightClick = 5
    case scroll = 6
    case leftClick = 7
    case pinchZoom = 8
    case missionControl = 9
    case switchSpaceLeft = 10
    case switchSpaceRight = 11
}

public struct TouchInputPacket: Sendable {
    public var kind: TouchEventKind
    public var isPencil: Bool
    public var clickCount: UInt8
    public var phase: UInt8 // 0=none, 1=began, 2=changed, 3=ended, 4=momentum
    public var normX: Float
    public var normY: Float
    public var deltaX: Float
    public var deltaY: Float
    public var pressure: Float // 0.0...1.0 for Apple Pencil

    public init(
        kind: TouchEventKind,
        normX: Float,
        normY: Float,
        deltaX: Float = 0,
        deltaY: Float = 0,
        pressure: Float = 0.5,
        isPencil: Bool = false,
        clickCount: UInt8 = 1,
        phase: UInt8 = 0
    ) {
        self.kind = kind
        self.isPencil = isPencil
        self.clickCount = clickCount
        self.phase = phase
        self.normX = normX
        self.normY = normY
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.pressure = pressure
    }

    public func encode() -> Data {
        var data = Data(capacity: 24)
        data.append(kind.rawValue)
        data.append(isPencil ? 1 : 0)
        data.append(clickCount)
        data.append(phase)
        var x = normX.bitPattern.littleEndian
        var y = normY.bitPattern.littleEndian
        var dx = deltaX.bitPattern.littleEndian
        var dy = deltaY.bitPattern.littleEndian
        var p = pressure.bitPattern.littleEndian
        withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &y) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &dx) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &dy) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &p) { data.append(contentsOf: $0) }
        return data
    }

    public static func decode(_ data: Data) -> TouchInputPacket? {
        guard data.count >= 24, let kind = TouchEventKind(rawValue: data[data.startIndex]) else { return nil }
        return data.withUnsafeBytes { raw -> TouchInputPacket? in
            let base = raw.baseAddress!
            let isPencil = base.load(fromByteOffset: 1, as: UInt8.self) != 0
            let clickCount = base.load(fromByteOffset: 2, as: UInt8.self)
            let phase = base.load(fromByteOffset: 3, as: UInt8.self)
            let x = Float(bitPattern: UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))
            let y = Float(bitPattern: UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
            let dx = Float(bitPattern: UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 12, as: UInt32.self)))
            let dy = Float(bitPattern: UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 16, as: UInt32.self)))
            let p = Float(bitPattern: UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 20, as: UInt32.self)))
            return TouchInputPacket(
                kind: kind, normX: x, normY: y, deltaX: dx, deltaY: dy,
                pressure: p, isPencil: isPencil, clickCount: clickCount, phase: phase
            )
        }
    }
}

public struct PacketHeader: Sendable {
    public var type: PacketType
    public var flags: PacketFlags
    public var timestampNs: UInt64
    public var payloadLength: UInt32
    public var sequence: UInt32

    public init(type: PacketType, flags: PacketFlags = [], timestampNs: UInt64, payloadLength: UInt32, sequence: UInt32) {
        self.type = type
        self.flags = flags
        self.timestampNs = timestampNs
        self.payloadLength = payloadLength
        self.sequence = sequence
    }

    public func encode() -> Data {
        var data = Data(capacity: WireConstants.headerSize)
        var magic = WireConstants.magic.littleEndian
        var reserved: UInt16 = 0
        var ts = timestampNs.littleEndian
        var len = payloadLength.littleEndian
        var seq = sequence.littleEndian

        withUnsafeBytes(of: &magic) { data.append(contentsOf: $0) }
        data.append(type.rawValue)
        data.append(flags.rawValue)
        withUnsafeBytes(of: &reserved) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &ts) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &seq) { data.append(contentsOf: $0) }
        return data
    }

    public static func decode(_ data: Data) -> PacketHeader? {
        guard data.count >= WireConstants.headerSize else { return nil }
        return data.withUnsafeBytes { raw -> PacketHeader? in
            let base = raw.baseAddress!
            let magic = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            guard magic == WireConstants.magic else { return nil }
            let typeRaw = base.load(fromByteOffset: 4, as: UInt8.self)
            guard let type = PacketType(rawValue: typeRaw) else { return nil }
            let flags = PacketFlags(rawValue: base.load(fromByteOffset: 5, as: UInt8.self))
            let ts = UInt64(littleEndian: base.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
            let len = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 16, as: UInt32.self))
            let seq = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 20, as: UInt32.self))
            return PacketHeader(type: type, flags: flags, timestampNs: ts, payloadLength: len, sequence: seq)
        }
    }
}

public enum MonotonicClock {
    public static func nowNs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

public enum SocketIO {
    public static func sendAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return true }
            var totalSent = 0
            let count = rawBuffer.count
            while totalSent < count {
                let n = Darwin.send(fd, base.advanced(by: totalSent), count - totalSent, 0)
                if n > 0 {
                    totalSent += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    public static func recvExact(fd: Int32, count: Int) -> Data? {
        if count == 0 { return Data() }
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return false }
            var totalRead = 0
            while totalRead < count {
                let n = Darwin.recv(fd, base.advanced(by: totalRead), count - totalRead, 0)
                if n > 0 {
                    totalRead += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        return ok ? data : nil
    }

    public static func configureLowLatencySocket(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var bufSize: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
    }
}

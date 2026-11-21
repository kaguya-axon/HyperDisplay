import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

final class VideoEncoder {
    var onEncodedFrame: ((_ payload: Data, _ isKeyframe: Bool, _ captureTimestampNs: UInt64, _ encodeMs: Double) -> Void)?
    var onLog: ((String) -> Void)?

    private var session: VTCompressionSession?
    private let encodeQueue = DispatchQueue(label: "com.axonter.hyperdisplay.encoder", qos: .userInteractive)
    private var forceKeyframeFlag = false
    private(set) var activeMode: CodecProfileMode = .hevc42210
    private var currentWidth: Int = 0
    private var currentHeight: Int = 0
    private var currentFPS: Int = 120
    private var currentBitrateMbps: Int = 220
    private var currentPrioritizeSpeed: Bool = false

    func configure(
        width: Int,
        height: Int,
        fps: Int,
        bitrateMbps: Int,
        preferredMode: CodecProfileMode,
        prioritizeSpeed: Bool = false
    ) -> CodecProfileMode {
        return encodeQueue.sync {
            invalidateLocked()
            currentWidth = width
            currentHeight = height
            currentFPS = fps
            currentBitrateMbps = bitrateMbps
            currentPrioritizeSpeed = prioritizeSpeed

            let fallbacks: [CodecProfileMode]
            switch preferredMode {
            case .hevc42210: fallbacks = [.hevc42210, .hevc10, .hevc8]
            case .hevc10: fallbacks = [.hevc10, .hevc8]
            case .hevc8: fallbacks = [.hevc8]
            }

            for mode in fallbacks {
                if tryCreateSessionLocked(
                    width: width,
                    height: height,
                    fps: fps,
                    bitrateMbps: bitrateMbps,
                    mode: mode,
                    prioritizeSpeed: prioritizeSpeed
                ) {
                    activeMode = mode
                    forceKeyframeFlag = true
                    onLog?("编码器就绪: \(width)x\(height) @ \(fps)Hz, \(bitrateMbps)Mbps, \(mode.shortLabel), speedPriority=\(prioritizeSpeed)")
                    return mode
                }
            }

            activeMode = .hevc8
            onLog?("警告: 硬件编码器初始化失败")
            return .hevc8
        }
    }

    func updateBitrate(_ bitrateMbps: Int) {
        encodeQueue.async { [weak self] in
            guard let self, let s = self.session else { return }
            self.currentBitrateMbps = bitrateMbps
            let bps = bitrateMbps * 1_000_000
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bps))
            let bytesPerSec = Double(bps) / 8.0 * 1.2
            let limits: [NSNumber] = [NSNumber(value: bytesPerSec), NSNumber(value: 1.0)]
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
        }
    }

    func requestKeyframe() {
        encodeQueue.async { [weak self] in
            self?.forceKeyframeFlag = true
        }
    }

    func encode(pixelBuffer: CVPixelBuffer, captureTimestampNs: UInt64) {
        encodeQueue.async { [weak self] in
            guard let self, let s = self.session else { return }
            let pts = CMTime(value: Int64(bitPattern: captureTimestampNs), timescale: 1_000_000_000)
            let duration = CMTime(value: 1, timescale: CMTimeScale(max(1, self.currentFPS)))

            var frameProps: CFDictionary?
            if self.forceKeyframeFlag {
                self.forceKeyframeFlag = false
                frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
            }

            var infoFlags = VTEncodeInfoFlags()
            let status = VTCompressionSessionEncodeFrame(
                s,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: pts,
                duration: duration,
                frameProperties: frameProps,
                sourceFrameRefcon: nil,
                infoFlagsOut: &infoFlags
            )
            if status != noErr {
                self.onLog?("编码帧错误: \(status)")
            }
        }
    }

    func invalidate() {
        encodeQueue.sync {
            invalidateLocked()
        }
    }

    private func invalidateLocked() {
        if let s = session {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
            session = nil
        }
    }

    private func tryCreateSessionLocked(
        width: Int,
        height: Int,
        fps: Int,
        bitrateMbps: Int,
        mode: CodecProfileMode,
        prioritizeSpeed: Bool
    ) -> Bool {
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanTrue!,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue!
        ]

        let callback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
            guard status == noErr, let refcon, let sampleBuffer else { return }
            let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
            encoder.handleEncodedSample(sampleBuffer)
        }

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &created
        )
        guard status == noErr, let s = created else { return false }

        let profile: CFString
        switch mode {
        case .hevc42210: profile = kVTProfileLevel_HEVC_Main42210_AutoLevel
        case .hevc10: profile = kVTProfileLevel_HEVC_Main10_AutoLevel
        case .hevc8: profile = kVTProfileLevel_HEVC_Main_AutoLevel
        }

        guard VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: profile) == noErr else {
            VTCompressionSessionInvalidate(s)
            return false
        }

        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 2))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2.0))
        VTSessionSetProperty(
            s,
            key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            value: prioritizeSpeed ? kCFBooleanTrue : kCFBooleanFalse
        )

        let bps = bitrateMbps * 1_000_000
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bps))
        let bytesPerSec = Double(bps) / 8.0 * 1.2
        let limits: [NSNumber] = [NSNumber(value: bytesPerSec), NSNumber(value: 1.0)]
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)

        // Tag Display P3 color primaries for accurate reproduction on iPad Pro OLED/mini-LED.
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_P3_D65)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)

        guard VTCompressionSessionPrepareToEncodeFrames(s) == noErr else {
            VTCompressionSessionInvalidate(s)
            return false
        }

        session = s
        return true
    }

    private func handleEncodedSample(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let captureTs = UInt64(bitPattern: pts.value)
        let nowNs = MonotonicClock.nowNs()
        let encodeMs = nowNs >= captureTs ? Double(nowNs - captureTs) / 1_000_000.0 : 0.0

        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        }

        var totalLen = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLen,
            dataPointerOut: &dataPtr
        ) == kCMBlockBufferNoErr, let dataPtr, totalLen > 0 else {
            return
        }

        var payload: Data
        if isKeyframe, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var paramCount = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &paramCount, nalUnitHeaderLengthOut: nil
            )
            payload = Data(capacity: 256 + totalLen)
            payload.append(UInt8(min(paramCount, 255)))
            for idx in 0..<min(paramCount, 255) {
                var pPtr: UnsafePointer<UInt8>?
                var pSize: Int = 0
                let st = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    fmt, parameterSetIndex: idx, parameterSetPointerOut: &pPtr,
                    parameterSetSizeOut: &pSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
                if st == noErr, let pPtr, pSize > 0, pSize <= Int(UInt16.max) {
                    var lenLE = UInt16(pSize).littleEndian
                    withUnsafeBytes(of: &lenLE) { payload.append(contentsOf: $0) }
                    payload.append(pPtr, count: pSize)
                }
            }
            payload.append(UnsafeRawPointer(dataPtr).assumingMemoryBound(to: UInt8.self), count: totalLen)
        } else {
            payload = Data(bytes: dataPtr, count: totalLen)
        }

        onEncodedFrame?(payload, isKeyframe, captureTs, encodeMs)
    }
}

import UIKit
import AVFoundation
import CoreMedia
import VideoToolbox

final class VideoDisplayView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    var onRequestKeyframe: (() -> Void)?
    var onDecodeError: ((String) -> Void)?

    private var formatDescription: CMVideoFormatDescription?
    private let decodeQueue = DispatchQueue(label: "com.axonter.hyperdisplay.ipad.decode", qos: .userInteractive)
    private var lastKeyframeRequestTime: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        displayLayer.preventsCapture = false
        if #available(iOS 17.0, *) {
            displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: false)
        }
    }

    func reset() {
        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.formatDescription = nil
            DispatchQueue.main.async {
                if #available(iOS 17.0, *) {
                    self.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
                } else {
                    self.displayLayer.flushAndRemoveImage()
                }
            }
        }
    }

    func enqueueVideoFrame(header: PacketHeader, payload: Data) {
        decodeQueue.async { [weak self] in
            self?.processVideoFrame(header: header, payload: payload)
        }
    }

    private func processVideoFrame(header: PacketHeader, payload: Data) {
        let isKeyframe = header.flags.contains(.keyframe)
        var naluStartOffset = 0

        if isKeyframe {
            guard !payload.isEmpty else { return }
            let paramCount = Int(payload[0])
            var offset = 1
            var paramSets: [Data] = []
            paramSets.reserveCapacity(paramCount)

            for _ in 0..<paramCount {
                guard offset + 2 <= payload.count else { return }
                let len = Int(UInt16(payload[offset]) | (UInt16(payload[offset + 1]) << 8))
                offset += 2
                guard offset + len <= payload.count else { return }
                paramSets.append(payload.subdata(in: offset..<(offset + len)))
                offset += len
            }
            naluStartOffset = offset

            if !paramSets.isEmpty, let fmt = makeHEVCFormatDescription(paramSets: paramSets) {
                self.formatDescription = fmt
            }
        }

        guard let formatDescription else {
            throttledKeyframeRequest()
            return
        }

        let naluLength = payload.count - naluStartOffset
        guard naluLength > 4 else { return }

        // Allocate owned CMBlockBuffer and copy NALU bytes directly.
        var blockBuffer: CMBlockBuffer?
        let allocStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: naluLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: naluLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard allocStatus == kCMBlockBufferNoErr, let blockBuffer else { return }

        let copyStatus = payload.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base.advanced(by: naluStartOffset),
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: naluLength
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = naluLength
        let sbStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sampleBuffer else { return }

        // Display immediately with zero presentation queue delay.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
            if !isKeyframe {
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }

        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            let errMsg = renderer.error?.localizedDescription ?? "解码器状态异常"
            renderer.flush()
            onDecodeError?(errMsg)
            throttledKeyframeRequest()
            return
        }

        if !renderer.isReadyForMoreMediaData {
            renderer.flush()
        }
        renderer.enqueue(sampleBuffer)
    }

    private func makeHEVCFormatDescription(paramSets: [Data]) -> CMVideoFormatDescription? {
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        var keptBuffers: [UnsafeMutablePointer<UInt8>] = []

        defer {
            for buf in keptBuffers { buf.deallocate() }
        }

        for ps in paramSets {
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: ps.count)
            ps.copyBytes(to: buf, count: ps.count)
            keptBuffers.append(buf)
            pointers.append(UnsafePointer(buf))
            sizes.append(ps.count)
        }

        var desc: CMVideoFormatDescription?
        let status = pointers.withUnsafeBufferPointer { ptrBuf in
            sizes.withUnsafeBufferPointer { sizeBuf in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: paramSets.count,
                    parameterSetPointers: ptrBuf.baseAddress!,
                    parameterSetSizes: sizeBuf.baseAddress!,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &desc
                )
            }
        }
        return status == noErr ? desc : nil
    }

    private func throttledKeyframeRequest() {
        let now = CACurrentMediaTime()
        if now - lastKeyframeRequestTime > 0.5 {
            lastKeyframeRequestTime = now
            onRequestKeyframe?()
        }
    }
}

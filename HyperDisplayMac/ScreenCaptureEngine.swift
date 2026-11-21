import Foundation
import ScreenCaptureKit
import CoreVideo
import CoreMedia
import CoreGraphics

final class ScreenCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer, UInt64) -> Void)?
    var onError: ((String) -> Void)?

    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "com.axonter.hyperdisplay.capture", qos: .userInteractive)

    func start(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int, fps: Int, useTenBit: Bool) async throws {
        await stop()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let targetDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "HyperDisplay", code: -1, userInfo: [NSLocalizedDescriptionKey: "未在 ScreenCaptureKit 中找到虚拟显示器 #\(displayID)"])
        }

        let filter = SCContentFilter(display: targetDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        config.queueDepth = 3
        config.showsCursor = true
        config.capturesAudio = false
        config.colorSpaceName = CGColorSpace.displayP3

        if useTenBit {
            config.pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked
        } else {
            config.pixelFormat = kCVPixelFormatType_32BGRA
        }

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await newStream.startCapture()
        self.stream = newStream
    }

    func stop() async {
        guard let active = stream else { return }
        stream = nil
        try? await active.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else {
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer, MonotonicClock.nowNs())
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("截屏流中断: \(error.localizedDescription)")
    }
}

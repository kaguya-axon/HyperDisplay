import Foundation
import CoreGraphics

final class VirtualDisplayManager {
    private var virtualDisplay: CGVirtualDisplay?
    private let queue = DispatchQueue(label: "com.axonter.hyperdisplay.virtualdisplay")

    private(set) var displayID: CGDirectDisplayID = 0
    private(set) var currentPixelWidth: Int = 0
    private(set) var currentPixelHeight: Int = 0

    func createDisplay(
        name: String,
        pixelWidth: Int,
        pixelHeight: Int,
        scaleFactor: Double,
        refreshRate: Double
    ) -> CGDirectDisplayID? {
        destroyDisplay()

        // Ensure even pixel dimensions for HEVC 4:2:2 / 4:2:0 encoders.
        let evenW = max(640, (pixelWidth / 2) * 2)
        let evenH = max(480, (pixelHeight / 2) * 2)

        // Logical points for HiDPI mode. scaleFactor=1.0 -> native 2x Retina (pixel / 2).
        // scaleFactor > 1.0 -> slightly more workspace area while keeping HiDPI sharp.
        let logicalW = UInt32(max(640, Int((Double(evenW) / 2.0) * scaleFactor)))
        let logicalH = UInt32(max(480, Int((Double(evenH) / 2.0) * scaleFactor)))

        // Allocate framebuffer large enough for 2x HiDPI of logical resolution.
        let maxW = max(UInt32(evenW), logicalW * 2)
        let maxH = max(UInt32(evenH), logicalH * 2)

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = queue
        descriptor.name = name
        descriptor.vendorID = 0x1337
        descriptor.productID = 0x1200
        descriptor.serialNum = 0x20261121
        descriptor.maxPixelsWide = maxW
        descriptor.maxPixelsHigh = maxH

        // Physical size roughly matching 11" / 13" iPad Pro (~264 PPI).
        let mmW = Double(evenW) / 264.0 * 25.4
        let mmH = Double(evenH) / 264.0 * 25.4
        descriptor.sizeInMillimeters = CGSize(width: mmW, height: mmH)

        // Display P3 primaries + D65 white point.
        descriptor.redPrimary = CGPoint(x: 0.680, y: 0.320)
        descriptor.greenPrimary = CGPoint(x: 0.265, y: 0.690)
        descriptor.bluePrimary = CGPoint(x: 0.150, y: 0.060)
        descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)

        descriptor.terminationHandler = { _, _ in }

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            return nil
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.rotation = 0

        var modes: [CGVirtualDisplayMode] = [
            CGVirtualDisplayMode(width: logicalW, height: logicalH, refreshRate: refreshRate)
        ]
        if refreshRate != 60.0 {
            modes.append(CGVirtualDisplayMode(width: logicalW, height: logicalH, refreshRate: 60.0))
        }
        settings.modes = modes

        guard display.apply(settings) else {
            return nil
        }

        self.virtualDisplay = display
        self.displayID = display.displayID
        self.currentPixelWidth = evenW
        self.currentPixelHeight = evenH
        return display.displayID
    }

    func destroyDisplay() {
        virtualDisplay = nil
        displayID = 0
        currentPixelWidth = 0
        currentPixelHeight = 0
    }
}

import CoreGraphics
import Foundation
import ImageIO

/// Builds camera-style live-view datagrams. Used by the UI-test fixture and unit
/// tests so both exercise the same parser as real camera traffic.
enum LumixLiveViewPacketBuilder {
    struct Exposure {
        var apertureClosed: Double
        var apertureOpen: Double
        var aperture: Double
        var shutterFastest: Double
        var shutterSlowest: Double
        var shutter: Double
        var exposureThirds: Int8
    }

    static func datagram(
        jpeg: Data,
        extensionType: Int16? = 5,
        frames: [LumixLiveViewFrameMetadata.AFFrame] = [],
        exposure: Exposure? = nil,
        trailingPadding: Int = 0
    ) -> Data {
        var extensionData = Data()
        if let extensionType {
            extensionData.appendInt16(extensionType)
            let wide = extensionType == 10 || extensionType == 12
            if [1, 5, 6, 8, 9, 10, 12].contains(extensionType) {
                extensionData.appendInt16(0)
                extensionData.append(Data(count: 11))
                extensionData.append(UInt8(min(frames.count, 255)))
                for frame in frames.prefix(255) {
                    [frame.x0, frame.y0, frame.x1, frame.y1].forEach { extensionData.appendInt16(Int16($0)) }
                    extensionData.append(contentsOf: [frame.red, frame.green, frame.blue, frame.kind])
                    if wide { extensionData.append(Data(count: 4)) }
                }
            }
            if [5, 6, 8, 9, 10, 12].contains(extensionType) {
                let exposure = exposure ?? Exposure(
                    apertureClosed: 9, apertureOpen: 3, aperture: 4, shutterFastest: 14,
                    shutterSlowest: -6, shutter: 6, exposureThirds: 0
                )
                for apex in [exposure.apertureClosed, exposure.apertureOpen, exposure.aperture,
                             exposure.shutterFastest, exposure.shutterSlowest, exposure.shutter] {
                    extensionData.appendInt16(Int16((apex * 256).rounded()))
                    extensionData.appendInt16(256)
                }
                for _ in 0..<6 { extensionData.appendInt16(0) }
                extensionData.append(UInt8(bitPattern: exposure.exposureThirds))
            }
        }

        let total = 32 + extensionData.count + jpeg.count + trailingPadding
        var header = Data(count: 32)
        header[0] = UInt8((total >> 8) & 0xFF)
        header[1] = UInt8(total & 0xFF)
        header[2] = 0x01
        header[3] = 0x00
        let exampleMAC: [UInt8] = [0x02, 0x00, 0x00, 0x00, 0x00, 0x01]
        for (offset, byte) in exampleMAC.enumerated() { header[9 + offset] = byte }
        header[30] = UInt8((extensionData.count >> 8) & 0xFF)
        header[31] = UInt8(extensionData.count & 0xFF)
        return header + extensionData + jpeg + Data(repeating: 0xFF, count: trailingPadding)
    }

    /// A small JPEG with a gradient sky and a sun at `phase` (0…1) across the frame.
    static func syntheticJPEG(width: Int = 320, height: Int = 240, phase: Double = 0.3) -> Data? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let colors = [CGColor(red: 0.42, green: 0.62, blue: 0.86, alpha: 1),
                      CGColor(red: 0.95, green: 0.78, blue: 0.55, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: .zero, options: [])
        }
        let sun = CGFloat(height) * 0.18
        context.setFillColor(CGColor(red: 1, green: 0.97, blue: 0.85, alpha: 1))
        context.fillEllipse(in: CGRect(x: CGFloat(width) * CGFloat(phase) - sun / 2, y: CGFloat(height) * 0.62, width: sun, height: sun))
        context.setFillColor(CGColor(red: 0.18, green: 0.32, blue: 0.24, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 3))
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

private extension Data {
    mutating func appendInt16(_ value: Int16) {
        let bits = UInt16(bitPattern: value)
        append(UInt8(bits >> 8))
        append(UInt8(bits & 0xFF))
    }
}

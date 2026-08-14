import Foundation
import UIKit

actor DemoCameraGalleryClient: CameraGalleryClient {
    private let total: Int

    init(total: Int = 25) {
        self.total = total
    }

    func prepareForBrowsing() async throws -> Int { total }

    func browsePhotos(start: Int, count: Int) async throws -> LumixPhotoPage {
        let upperBound = min(total, start + count)
        let photos = start < upperBound ? (start..<upperBound).map(Self.photo) : []
        return LumixPhotoPage(
            startIndex: start,
            numberReturned: photos.count,
            totalMatches: total,
            photos: photos
        )
    }

    func downloadJPEGData(_ resource: LumixResource) async throws -> Data {
        guard let data = Self.renderedJPEG(for: resource) else {
            throw DemoError.mediaUnavailable
        }
        return data
    }

    func download(_ resource: LumixResource) async throws -> URL {
        throw DemoError.mediaUnavailable
    }

    static func photos(_ count: Int) -> [LumixPhoto] {
        Array((0..<max(0, count)).map(Self.photo).reversed())
    }

    static func photo(_ index: Int) -> LumixPhoto {
        let sequence = String(format: "%04d", index + 1)
        let itemID = "DEMO-\(sequence)"
        let thumbnail = LumixResource(
            itemID: itemID,
            title: "Demo scene \(sequence)",
            url: URL(string: "http://192.168.54.1:50001/DT\(sequence).JPG")!,
            protocolInfo: "http-get:*:image/jpeg;PANASONIC.COM_PN=CAM_TN"
        )
        let original = LumixResource(
            itemID: itemID,
            title: "Demo scene \(sequence)",
            url: URL(string: "http://192.168.54.1:50001/DO\(sequence).JPG")!,
            protocolInfo: "http-get:*:image/jpeg;PANASONIC.COM_PN=CAM_ORG"
        )
        return LumixPhoto(itemID: itemID, title: "Demo scene \(sequence)", resources: [thumbnail, original])
    }

    /// Generates deterministic, clearly synthetic scenery for UI tests and App Store captures.
    /// No camera-roll or camera-card content is ever read by the fixture.
    private static func renderedJPEG(for resource: LumixResource) -> Data? {
        let sequence = resource.itemID
            .flatMap { Int($0.split(separator: "-").last ?? "1") } ?? 1
        let index = max(0, sequence - 1)
        let size = CGSize(width: 1_200, height: 900)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1

        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            let hue = CGFloat((index * 37) % 360) / 360
            let skyTop = UIColor(hue: hue, saturation: 0.38, brightness: 0.98, alpha: 1)
            let skyBottom = UIColor(
                hue: (hue + 0.12).truncatingRemainder(dividingBy: 1),
                saturation: 0.58,
                brightness: 0.72,
                alpha: 1
            )

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: [skyTop.cgColor, skyBottom.cgColor] as CFArray,
                locations: [0, 1]
            )!
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: size.height),
                options: []
            )

            let sunX = CGFloat(150 + ((index * 173) % 820))
            let sunY = CGFloat(130 + ((index * 61) % 220))
            context.setFillColor(UIColor.white.withAlphaComponent(0.82).cgColor)
            context.fillEllipse(in: CGRect(x: sunX, y: sunY, width: 150, height: 150))

            for layer in 0..<3 {
                let baseline = CGFloat(500 + (layer * 110))
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: size.height))
                path.addLine(to: CGPoint(x: 0, y: baseline))

                let step = size.width / 4
                for peak in 0...4 {
                    let x = CGFloat(peak) * step
                    let offset = CGFloat((index * 47 + layer * 83 + peak * 97) % 170)
                    path.addLine(to: CGPoint(x: x, y: baseline - 80 - offset))
                }

                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                let brightness = CGFloat(0.48 - (Double(layer) * 0.09))
                context.setFillColor(
                    UIColor(
                        hue: (hue + 0.35).truncatingRemainder(dividingBy: 1),
                        saturation: 0.45,
                        brightness: brightness,
                        alpha: 1
                    ).cgColor
                )
                context.addPath(path)
                context.fillPath()
            }

            let foreground = CGRect(x: 0, y: 760, width: size.width, height: 140)
            context.setFillColor(
                UIColor(
                    hue: (hue + 0.52).truncatingRemainder(dividingBy: 1),
                    saturation: 0.5,
                    brightness: 0.23,
                    alpha: 1
                ).cgColor
            )
            context.fill(foreground)

            context.setStrokeColor(UIColor.white.withAlphaComponent(0.32).cgColor)
            context.setLineWidth(8)
            for line in 0..<4 {
                let y = CGFloat(790 + (line * 28))
                context.move(to: CGPoint(x: CGFloat((index * 29 + line * 71) % 180), y: y))
                context.addLine(to: CGPoint(x: size.width - CGFloat((index * 19 + line * 53) % 210), y: y))
                context.strokePath()
            }
        }

        return image.jpegData(compressionQuality: 0.9)
    }

    private enum DemoError: LocalizedError {
        case mediaUnavailable

        var errorDescription: String? { "Demo media is intentionally unavailable." }
    }
}

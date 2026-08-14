import Foundation

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
        throw DemoError.mediaUnavailable
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
            title: "GM1S \(sequence)",
            url: URL(string: "http://192.168.54.1:50001/DT\(sequence).JPG")!,
            protocolInfo: "http-get:*:image/jpeg;PANASONIC.COM_PN=CAM_TN"
        )
        let original = LumixResource(
            itemID: itemID,
            title: "GM1S \(sequence)",
            url: URL(string: "http://192.168.54.1:50001/DO\(sequence).JPG")!,
            protocolInfo: "http-get:*:image/jpeg;PANASONIC.COM_PN=CAM_ORG"
        )
        return LumixPhoto(itemID: itemID, title: "GM1S \(sequence)", resources: [thumbnail, original])
    }

    private enum DemoError: LocalizedError {
        case mediaUnavailable

        var errorDescription: String? { "Demo media is intentionally unavailable." }
    }
}

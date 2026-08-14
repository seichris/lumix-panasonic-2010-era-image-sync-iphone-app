import Foundation
import XCTest
@testable import GM1Sync

final class CameraImportTests: XCTestCase {
    func testPhotoPlansExposeJPEGPairedAndRAWImports() throws {
        let photo = LumixPhoto(
            itemID: "1280475",
            title: "128-0475",
            resources: [
                resource(filename: "DO1280475.JPG", profile: "CAM_RAW_JPG", mimeType: "image/jpeg"),
                resource(filename: "DO1280475.RW2", profile: "CAM_RAW", mimeType: "application/octet-stream")
            ]
        )

        XCTAssertTrue(photo.supports(.jpeg))
        XCTAssertTrue(photo.supports(.jpegAndRAW))
        XCTAssertTrue(photo.supports(.raw))

        let jpeg = try photo.importPlan(photoMode: .jpeg)
        XCTAssertEqual(jpeg.variant, .jpeg)
        XCTAssertEqual(jpeg.resources.map(\.role), [.photo])

        let paired = try photo.importPlan(photoMode: .jpegAndRAW)
        XCTAssertEqual(paired.variant, .jpegAndRAW)
        XCTAssertEqual(paired.resources.map(\.role), [.photo, .alternatePhoto])
        XCTAssertEqual(paired.resources.map(\.cameraResource.url.pathExtension), ["JPG", "RW2"])

        let raw = try photo.importPlan(photoMode: .raw)
        XCTAssertEqual(raw.variant, .raw)
        XCTAssertEqual(raw.resources.map(\.role), [.photo])
        XCTAssertEqual(raw.resources.first?.cameraResource.url.pathExtension, "RW2")
    }

    func testJPEGOnlyPhotoDoesNotOfferRAWModes() {
        let photo = LumixPhoto(
            itemID: "1",
            title: "JPEG only",
            resources: [resource(filename: "D0001.JPG", profile: "CAM_ORG", mimeType: "image/jpeg")]
        )

        XCTAssertTrue(photo.supports(.jpeg))
        XCTAssertFalse(photo.supports(.jpegAndRAW))
        XCTAssertFalse(photo.supports(.raw))
    }

    func testVideoPlanPrefersMP4AndFallsBackToAVCHD() throws {
        let avchd = resource(filename: "00001.MTS", profile: "CAM_AVCHD", mimeType: "video/mp2t")
        let mp4 = resource(filename: "P0001.MP4", profile: "CAM_MP4", mimeType: "video/mp4")
        let video = LumixPhoto(itemID: "2", title: "Video", resources: [avchd, mp4])

        XCTAssertEqual(video.kind, .video)
        XCTAssertEqual(video.videoResource, mp4)
        let plan = try video.importPlan(photoMode: .jpeg)
        XCTAssertEqual(plan.variant, .video)
        XCTAssertEqual(plan.resources.map(\.role), [.video])
        XCTAssertEqual(plan.resources.first?.cameraResource, mp4)

        let avchdOnly = LumixPhoto(itemID: "3", title: "AVCHD", resources: [avchd])
        XCTAssertEqual(avchdOnly.videoResource, avchd)
        XCTAssertEqual(try avchdOnly.importPlan(photoMode: .raw).variant, .video)
    }

    func testDIDLParserRecognizesCameraVideoResource() throws {
        let xml = """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
          <item id="video-1">
            <dc:title>P0001</dc:title>
            <upnp:class>object.item.videoItem</upnp:class>
            <res protocolInfo="http-get:*:video/mp4;PANASONIC.COM_PN=CAM_MP4">http://192.168.54.1:50001/P0001.MP4</res>
          </item>
        </DIDL-Lite>
        """

        let resource = try XCTUnwrap(DIDLParser.parse(xml).first)
        XCTAssertEqual(resource.upnpClass, "object.item.videoItem")
        XCTAssertEqual(resource.mimeType, "video/mp4")
        XCTAssertTrue(resource.isVideo)
        XCTAssertEqual(LumixPhoto.grouped(from: [resource]).first?.kind, .video)
    }

    func testLegacyAVCHDPlaceholderResolvesToDownloadableMTS() throws {
        let placeholder = resource(
            filename: "DO193986570001.JPG",
            profile: "CAM_AVCHD",
            mimeType: "image/jpeg"
        )
        let video = LumixPhoto(itemID: "video-legacy", title: "Legacy AVCHD", resources: [placeholder])

        XCTAssertTrue(placeholder.isVideo)
        XCTAssertFalse(placeholder.isOriginalJPEG)
        XCTAssertEqual(placeholder.downloadURL.lastPathComponent, "DO19398657-0001.MTS")
        XCTAssertEqual(video.kind, .video)
        XCTAssertEqual(video.displayFilename, "DO19398657-0001.MTS")
        XCTAssertEqual(try video.importPlan(photoMode: .jpeg).resources.first?.cameraResource, placeholder)
    }

    func testOrdinaryJPEGKeepsItsAdvertisedDownloadURL() {
        let jpeg = resource(filename: "DO1280475.JPG", profile: "CAM_ORG", mimeType: "image/jpeg")

        XCTAssertFalse(jpeg.isVideo)
        XCTAssertTrue(jpeg.isOriginalJPEG)
        XCTAssertEqual(jpeg.downloadURL, jpeg.url)
    }

    private func resource(filename: String, profile: String, mimeType: String) -> LumixResource {
        LumixResource(
            itemID: "item",
            title: filename,
            url: URL(string: "http://192.168.54.1:50001/\(filename)")!,
            protocolInfo: "http-get:*:\(mimeType);PANASONIC.COM_PN=\(profile)"
        )
    }
}

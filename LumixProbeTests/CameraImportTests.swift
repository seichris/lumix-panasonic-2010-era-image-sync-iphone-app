import Foundation
import XCTest
@testable import GM1Sync

final class CameraImportTests: XCTestCase {
    func testLegacyHistoryWithoutEvidenceStillDecodesAsAnAppImport() throws {
        let data = Data(#"{"variants":["jpeg"],"lastImportedAt":0}"#.utf8)

        let record = try JSONDecoder().decode(CameraImportHistoryRecord.self, from: data)

        XCTAssertEqual(record.variants, [.jpeg])
        XCTAssertEqual(record.effectiveEvidence, .appImport)
    }

    func testImportFilenamesIncludeOriginalsButExcludeThumbnails() {
        let photo = LumixPhoto(
            itemID: "1280475",
            title: "128-0475",
            resources: [
                resource(filename: "DT1280475.JPG", profile: "CAM_TN", mimeType: "image/jpeg"),
                resource(filename: "DO1280475.JPG", profile: "CAM_RAW_JPG", mimeType: "image/jpeg"),
                resource(filename: "DO1280475.RW2", profile: "CAM_RAW", mimeType: "application/octet-stream")
            ]
        )

        XCTAssertEqual(photo.importFilenames, ["DO1280475.JPG", "DO1280475.RW2"])
    }

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

    func testVideoPlanPrefersMP4AndRejectsAVCHDWithoutCopyCapability() throws {
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
        XCTAssertFalse(avchdOnly.isImportable)
        XCTAssertThrowsError(try avchdOnly.importPlan(photoMode: .raw)) { error in
            XCTAssertEqual(error as? LumixError, .videoImportNotSupported)
        }
    }

    func testPlaybackPolicyAllowsMP4AndRejectsAVCHD() {
        let policy = CameraMediaPolicy()
        let mp4 = resource(filename: "P0001.MP4", profile: "CAM_MP4", mimeType: "video/mp4")
        let avchd = resource(
            filename: "DO00193986570000000001.TS",
            profile: "CAM_AVC_TS_HP_1080_60I_AC3",
            mimeType: "video/vnd.dlna.mpeg-tts"
        )

        XCTAssertTrue(policy.supportsPlayback(of: mp4))
        XCTAssertFalse(policy.supportsPlayback(of: avchd))
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

    func testLegacyAVCHDPlaceholderKeepsAdvertisedDLNAURL() throws {
        let placeholder = resource(
            filename: "DO193986570001.JPG",
            profile: "CAM_AVCHD",
            mimeType: "image/jpeg"
        )
        let video = LumixPhoto(itemID: "video-legacy", title: "Legacy AVCHD", resources: [placeholder])

        XCTAssertTrue(placeholder.isVideo)
        XCTAssertFalse(placeholder.isOriginalJPEG)
        XCTAssertTrue(placeholder.requiresDLNAStreamingRequest)
        XCTAssertEqual(placeholder.downloadURL.lastPathComponent, "DO193986570001.JPG")
        XCTAssertEqual(video.kind, .video)
        XCTAssertEqual(video.displayFilename, "DO193986570001.JPG")
        XCTAssertThrowsError(try video.importPlan(photoMode: .jpeg))
    }

    func testGM1AVCHDTransportStreamKeepsAdvertisedDLNAURL() throws {
        let placeholder = resource(
            filename: "DO00193986570000000001.TS",
            profile: "CAM_AVC_TS_HP_1080_50I_AC3",
            mimeType: "video/vnd.dlna.mpeg-tts"
        )
        let video = LumixPhoto(
            itemID: "00193986570000000001",
            title: "0019398657-0000000001",
            resources: [placeholder]
        )

        XCTAssertTrue(placeholder.isVideo)
        XCTAssertTrue(placeholder.requiresDLNAStreamingRequest)
        XCTAssertEqual(placeholder.downloadURL.lastPathComponent, "DO00193986570000000001.TS")
        XCTAssertEqual(video.displayFilename, "DO00193986570000000001.TS")
        XCTAssertThrowsError(try video.importPlan(photoMode: .jpeg)) { error in
            XCTAssertEqual(error as? LumixError, .videoImportNotSupported)
        }
    }

    func testGM1PlaybackPrefersPhoneSizedAVCHDResource() throws {
        let original = resource(
            filename: "DO00193986570000000001.TS",
            profile: "CAM_AVC_TS_HP_1080_50I_AC3",
            mimeType: "video/vnd.dlna.mpeg-tts"
        )
        let phonePlayback = resource(
            filename: "DO00193986570000000001_LOW.TS",
            profile: "CAM_AVC_TS_HP_360_25P_AAC",
            mimeType: "video/vnd.dlna.mpeg-tts"
        )
        let video = LumixPhoto(
            itemID: "00193986570000000001",
            title: "0019398657-0000000001",
            resources: [original, phonePlayback]
        )

        XCTAssertEqual(video.videoResource, original)
        XCTAssertEqual(video.videoPlaybackResource, phonePlayback)
        XCTAssertEqual(original.role, .highQuality1080)
        XCTAssertEqual(phonePlayback.role, .avchdPlayback360)
    }

    func testCapabilityParserSeparatesPlaybackFromIOSCopyPermission() throws {
        let xml = """
        <camrply>
          <result>ok</result>
          <contents_action_info model="DMC-GM1S" version="1.0" date="2014-10-01">
            <item>
              <content mime_type="video/vnd.dlna.mpeg-tts" panasonic_com_pn="CAM_AVC_TS_HP_1080_50I_AC3,CAM_AVC_TS_HP_360_25P_AAC">
                <action type="playback" enable="yes" os="ios" player="hls" player_func="play,pause,seek" />
                <action type="copy_to_sp" enable="yes" os="android" />
                <action type="copy_to_sp" enable="yes" />
                <action type="copy_to_sp" enable="no" os="ios" />
              </content>
            </item>
          </contents_action_info>
        </camrply>
        """
        let capabilities = CameraCapabilityParser.parse(Data(xml.utf8))
        let playback = resource(
            filename: "DO00193986570000000001_LOW.TS",
            profile: "CAM_AVC_TS_HP_360_25P_AAC",
            mimeType: "video/vnd.dlna.mpeg-tts"
        )

        XCTAssertEqual(capabilities.model, "DMC-GM1S")
        XCTAssertEqual(capabilities.entries.count, 1)
        XCTAssertEqual(capabilities.copyAllowed(for: playback), false)
        XCTAssertEqual(capabilities.playbackCapability(for: playback)?.enabled, true)
        XCTAssertEqual(capabilities.playbackCapability(for: playback)?.player, .dmpStream)
        XCTAssertEqual(capabilities.playbackCapability(for: playback)?.functions, ["play", "pause", "seek"])
    }

    func testExactCapabilityCanExplicitlyPermitAVCHDImport() throws {
        let avchd = resource(
            filename: "00001.MTS",
            profile: "CAM_AVC_TS_HP_720_25P_AAC",
            mimeType: "video/vnd.dlna.mpeg-tts"
        )
        let video = LumixPhoto(itemID: "3", title: "AVCHD", resources: [avchd])
        let capabilities = CameraCapabilities(
            model: "TEST",
            version: nil,
            date: nil,
            entries: [
                CameraCapabilityEntry(
                    mimeType: "video/vnd.dlna.mpeg-tts",
                    panasonicProfiles: ["CAM_AVC_TS_HP_720_25P_AAC"],
                    actions: [
                        CameraContentAction(
                            type: "copy_to_sp",
                            enabled: true,
                            operatingSystem: "ios",
                            player: nil,
                            playerFunctions: []
                        )
                    ]
                )
            ]
        )
        let policy = CameraMediaPolicy(capabilities: capabilities)

        XCTAssertTrue(policy.supportsImport(of: video, photoMode: .jpeg))
        XCTAssertEqual(
            try video.importPlan(photoMode: .jpeg, policy: policy).resources.first?.cameraResource,
            avchd
        )
    }

    func testDIDLParserPreservesPlaybackMetadataAndDLNAFlags() throws {
        let xml = """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
          <item id="00193986570000000001">
            <dc:title>0019398657-0000000001</dc:title>
            <upnp:class>object.item.videoItem</upnp:class>
            <res duration="00:01:02.500" resolution="640x360" size="123456" bitrate="789000" ChapterList="0,10" protocolInfo="http-get:*:video/vnd.dlna.mpeg-tts;PANASONIC.COM_PN=CAM_AVC_TS_HP_360_25P_AAC;DLNA.ORG_OP=01;DLNA.ORG_FLAGS=ABC">http://192.168.54.1:50001/LOW.TS</res>
          </item>
        </DIDL-Lite>
        """
        let resource = try XCTUnwrap(DIDLParser.parse(xml).first)

        XCTAssertEqual(resource.duration, 62.5)
        XCTAssertEqual(resource.resolutionWidth, 640)
        XCTAssertEqual(resource.resolutionHeight, 360)
        XCTAssertEqual(resource.size, 123456)
        XCTAssertEqual(resource.bitrate, 789000)
        XCTAssertEqual(resource.chapterList, "0,10")
        XCTAssertEqual(resource.dlnaOperations, "01")
        XCTAssertEqual(resource.dlnaFlags, "ABC")
        XCTAssertEqual(resource.role, .avchdPlayback360)
    }

    func testDIDLParserPreservesCameraItemCaptureDateForGeotagPreview() throws {
        let xml = """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
          <item id="photo-1">
            <dc:title>Photo 1</dc:title>
            <upnp:class>object.item.imageItem.photo</upnp:class>
            <res protocolInfo="http-get:*:image/jpeg;PANASONIC.COM_PN=CAM_ORG">http://192.168.54.1:50001/D0001.JPG</res>
            <dc:date>2026-08-15T06:30:00+08:00</dc:date>
          </item>
        </DIDL-Lite>
        """

        let resource = try XCTUnwrap(DIDLParser.parse(xml).first)
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-15T06:30:00+08:00"))
        XCTAssertEqual(resource.captureDate, expected)
        XCTAssertEqual(LumixPhoto.grouped(from: [resource]).first?.captureDate, expected)
    }

    func testBrowseMetadataSOAPTargetsTheSelectedItem() {
        let body = LumixBrowseSOAP.make(
            objectID: "00193986570000000001",
            flag: .metadata,
            start: 0,
            count: 1
        )

        XCTAssertTrue(body.contains("<ObjectID>00193986570000000001</ObjectID>"))
        XCTAssertTrue(body.contains("<BrowseFlag>BrowseMetadata</BrowseFlag>"))
        XCTAssertFalse(body.contains("X_FromCP"))
    }

    func testGM1AVCHDUsesPanasonicInitialDLNARequestExactly() throws {
        let url = try XCTUnwrap(
            URL(string: "http://192.168.54.1:50001/DO00193986570000000001.TS")
        )

        XCTAssertEqual(
            try LumixMediaHTTPRequest.make(for: url, style: .panasonicDLNAInitial),
            "GET /DO00193986570000000001.TS HTTP/1.1\r\n" +
                "User-Agent: Panasonic Android/1 DM-CP\r\n" +
                "Host: 192.168.54.1\r\n\r\n"
        )
    }

    func testPanasonicSeekRequestAddsByteRangeAfterHost() throws {
        let url = try XCTUnwrap(
            URL(string: "http://192.168.54.1:50001/DO00193986570000000001_LOW.TS")
        )

        XCTAssertEqual(
            try LumixMediaHTTPRequest.make(
                for: url,
                style: .panasonicDLNAInitial,
                rangeHeader: "bytes=1048576-"
            ),
            "GET /DO00193986570000000001_LOW.TS HTTP/1.1\r\n" +
                "User-Agent: Panasonic Android/1 DM-CP\r\n" +
                "Host: 192.168.54.1\r\n" +
                "Range: bytes=1048576-\r\n\r\n"
        )
    }

    func testPanasonicZeroBytePlayerProbeRemainsInitialPlainRequest() throws {
        XCTAssertNil(PanasonicDLNARemoteRange.fromLocalPlayerRange("bytes=0-1"))
        XCTAssertNil(PanasonicDLNARemoteRange.fromLocalPlayerRange("bytes=0-"))
        XCTAssertNil(PanasonicDLNARemoteRange.fromLocalPlayerRange(nil))
    }

    func testPanasonicPositivePlayerSeekBecomesCameraByteRange() throws {
        XCTAssertEqual(
            PanasonicDLNARemoteRange.fromLocalPlayerRange("bytes=1048576-"),
            "bytes=1048576-"
        )
        XCTAssertNil(PanasonicDLNARemoteRange.fromLocalPlayerRange("items=1-2"))
        XCTAssertNil(PanasonicDLNARemoteRange.fromLocalPlayerRange("bytes=-500"))
    }

    func testPanasonicRequestPreservesAdvertisedPercentEncodedTarget() throws {
        let url = try XCTUnwrap(
            URL(string: "http://192.168.54.1:50001/stream%20folder/video%2B1.TS?token=a%2Fb")
        )

        XCTAssertEqual(
            try LumixMediaHTTPRequest.make(for: url, style: .panasonicDLNAInitial),
            "GET /stream%20folder/video%2B1.TS?token=a%2Fb HTTP/1.1\r\n" +
                "User-Agent: Panasonic Android/1 DM-CP\r\n" +
                "Host: 192.168.54.1\r\n\r\n"
        )
    }

    func testOrdinaryJPEGKeepsItsAdvertisedDownloadURL() {
        let jpeg = resource(filename: "DO1280475.JPG", profile: "CAM_ORG", mimeType: "image/jpeg")

        XCTAssertFalse(jpeg.isVideo)
        XCTAssertTrue(jpeg.isOriginalJPEG)
        XCTAssertEqual(jpeg.downloadURL, jpeg.url)
    }

    func testCompleteJPEGAcceptsLegacyAdvertisedSizeMismatch() throws {
        XCTAssertNoThrow(
            try LumixMediaDownloadCompletion.validate(
                parsedHeaders: true,
                bodyCount: 6_329_397,
                expectedLength: 7_111_680,
                validatesJPEG: true,
                jpegComplete: true
            )
        )
    }

    func testIncompleteJPEGStillFailsAndIsRetryable() {
        XCTAssertThrowsError(
            try LumixMediaDownloadCompletion.validate(
                parsedHeaders: true,
                bodyCount: 6_329_397,
                expectedLength: 7_111_680,
                validatesJPEG: true,
                jpegComplete: false
            )
        ) { error in
            XCTAssertTrue(LumixMediaDownloadRetryPolicy.shouldRetry(error))
        }
    }

    func testIncompleteNonJPEGStillRequiresAdvertisedLength() {
        XCTAssertThrowsError(
            try LumixMediaDownloadCompletion.validate(
                parsedHeaders: true,
                bodyCount: 6_329_397,
                expectedLength: 7_111_680,
                validatesJPEG: false,
                jpegComplete: false
            )
        )
    }

    func testHTTP404IsNotRetried() {
        XCTAssertFalse(LumixMediaDownloadRetryPolicy.shouldRetry(LumixError.http(404, "Not Found")))
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

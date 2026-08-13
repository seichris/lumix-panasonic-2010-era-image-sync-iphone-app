import XCTest
@testable import LumixProbe

final class LumixWiFiCredentialsTests: XCTestCase {
    func testParsesStandardWPAWiFiPayload() throws {
        let credentials = try LumixWiFiCredentials(
            qrPayload: "WIFI:T:WPA;S:GM1S-90C7E0;P:secret123;;"
        )

        XCTAssertEqual(credentials.ssid, "GM1S-90C7E0")
        XCTAssertEqual(credentials.password, "secret123")
        XCTAssertFalse(credentials.isWEP)
    }

    func testParsesEscapedWiFiFields() throws {
        let credentials = try LumixWiFiCredentials(
            qrPayload: #"WIFI:T:WPA;S:GM1S\;ROOM;P:p\:a\;ss\\word;;"#
        )

        XCTAssertEqual(credentials.ssid, "GM1S;ROOM")
        XCTAssertEqual(credentials.password, #"p:a;ss\word"#)
    }

    func testParsesOpenNetworkCaseInsensitively() throws {
        let credentials = try LumixWiFiCredentials(
            qrPayload: "wifi:T:nopass;S:GM1S-OPEN;;"
        )

        XCTAssertEqual(credentials.ssid, "GM1S-OPEN")
        XCTAssertNil(credentials.password)
        XCTAssertFalse(credentials.isWEP)
    }

    func testParsesURLQueryFallback() throws {
        let credentials = try LumixWiFiCredentials(
            qrPayload: "lumix://connect?ssid=GM1S-URL&password=abc123&type=WEP"
        )

        XCTAssertEqual(credentials.ssid, "GM1S-URL")
        XCTAssertEqual(credentials.password, "abc123")
        XCTAssertTrue(credentials.isWEP)
    }

    func testRejectsUnknownPayloadWithoutExposingItsContents() {
        XCTAssertThrowsError(try LumixWiFiCredentials(qrPayload: "PANASONIC-PROPRIETARY")) { error in
            XCTAssertFalse(error.localizedDescription.contains("PANASONIC-PROPRIETARY"))
        }
    }

    func testRecognizesGM1SOriginalJPEGProfile() throws {
        let resource = LumixResource(
            itemID: "1280475",
            title: "128-0475",
            url: try XCTUnwrap(URL(string: "http://192.168.54.1:50001/DO1280475.JPG")),
            protocolInfo: "http-get:*:application/octet-stream;PANASONIC.COM_PN=CAM_RAW_JPG"
        )

        XCTAssertEqual(resource.profileName, "CAM_RAW_JPG")
        XCTAssertTrue(resource.isOriginalJPEG)
    }

    func testStillRecognizesNewerOriginalJPEGProfile() throws {
        let resource = LumixResource(
            itemID: nil,
            title: nil,
            url: try XCTUnwrap(URL(string: "http://camera/original.jpg")),
            protocolInfo: "http-get:*:image/jpeg;PANASONIC.COM_PN=CAM_ORG"
        )

        XCTAssertTrue(resource.isOriginalJPEG)
    }

    func testJPEGBoundaryIgnoresNestedThumbnailAndStuffedEntropyBytes() {
        let jpeg: [UInt8] = [
            0xff, 0xd8,
            0xff, 0xe1, 0x00, 0x08,
            0xff, 0xd8, 0xff, 0xd9, 0x00, 0x00,
            0xff, 0xda, 0x00, 0x02,
            0x11, 0xff, 0x00, 0xd9, 0x22,
            0xff, 0xd0, 0x33,
            0xff, 0xd9
        ]

        var detector = JPEGCompletionDetector()
        let completionIndex = jpeg.indices.first { detector.consume(jpeg[$0]) }

        XCTAssertEqual(completionIndex, jpeg.indices.last)
    }
}

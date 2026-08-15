import CryptoKit
import XCTest
@testable import GM1Sync

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

    func testParsesGM1SPlainPanasonicPayloadWithCRLF() throws {
        let payload = "CRYPT: PLANE\r\n\r\nSSID: GM1S-90C7E0\r\nPW: 12345678"
        XCTAssertEqual(payload.utf8.count, 48)

        let credentials = try LumixWiFiCredentials(qrPayload: payload)

        XCTAssertEqual(credentials.ssid, "GM1S-90C7E0")
        XCTAssertEqual(credentials.password, "12345678")
        XCTAssertFalse(credentials.isWEP)
    }

    func testParsesPanasonicPayloadWithModelAndOpenNetwork() throws {
        let credentials = try LumixWiFiCredentials(
            qrPayload: "MDL: GM1S\nCRYPT: PLANE\n\nSSID: GM1S-OPEN\n"
        )

        XCTAssertEqual(credentials.ssid, "GM1S-OPEN")
        XCTAssertNil(credentials.password)
        XCTAssertFalse(credentials.isWEP)
    }

    func testParsesCompactLegacyPanasonicPayload() throws {
        let credentials = try LumixWiFiCredentials(
            qrPayload: "PASS:camera-secret SSID:GM1S-LEGACY"
        )

        XCTAssertEqual(credentials.ssid, "GM1S-LEGACY")
        XCTAssertEqual(credentials.password, "camera-secret")
        XCTAssertFalse(credentials.isWEP)
    }

    func testRejectsEncryptedPanasonicPayloadWithoutExposingItsContents() {
        let payload = "MDL: GM1S\nCRYPT: AES\n\nvery-secret-body"

        XCTAssertThrowsError(try LumixWiFiCredentials(qrPayload: payload)) { error in
            XCTAssertFalse(error.localizedDescription.contains("very-secret-body"))
            XCTAssertTrue(error.localizedDescription.contains("reference"))
        }
    }

    func testRejectsUnknownPayloadWithoutExposingItsContents() {
        XCTAssertThrowsError(try LumixWiFiCredentials(qrPayload: "PANASONIC-PROPRIETARY")) { error in
            XCTAssertFalse(error.localizedDescription.contains("PANASONIC-PROPRIETARY"))
            XCTAssertTrue(error.localizedDescription.contains("reference"))
        }
    }

    func testUnsupportedPayloadReferenceIsDeterministicAndRedacted() {
        let secretPayload = "PANASONIC:SSID=GM1S;PASSWORD=do-not-show"
        let first = LumixQRCodeFingerprint.reference(for: secretPayload)
        let second = LumixQRCodeFingerprint.reference(for: secretPayload)

        XCTAssertEqual(first, second)
        XCTAssertFalse(first.contains("GM1S"))
        XCTAssertFalse(first.contains("do-not-show"))
    }

    func testUnsupportedPayloadReferenceDependsOnThePrivateInstallationKey() {
        let payload = "PANASONIC:SSID=GM1S;PASSWORD=12345678"
        let firstKey = SymmetricKey(data: Data(repeating: 0x11, count: 32))
        let secondKey = SymmetricKey(data: Data(repeating: 0x22, count: 32))

        let first = LumixQRCodeFingerprint.reference(for: payload, key: firstKey)
        let repeated = LumixQRCodeFingerprint.reference(for: payload, key: firstKey)
        let second = LumixQRCodeFingerprint.reference(for: payload, key: secondKey)

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.contains("12345678"))
    }

    func testRejectsMalformedWiFiPayloadWithoutExposingPassword() {
        let payload = "WIFI:T:WPA;P:top-secret;;"

        XCTAssertThrowsError(try LumixWiFiCredentials(qrPayload: payload)) { error in
            XCTAssertFalse(error.localizedDescription.contains("top-secret"))
        }
    }

    func testRejectsPasswordProtectedWiFiPayloadWithoutPassword() {
        XCTAssertThrowsError(try LumixWiFiCredentials(qrPayload: "WIFI:T:WPA;S:GM1S-MISSING-PASSWORD;;"))
    }

    func testManualCredentialsTrimSSIDAndNormalizeEmptyPassword() throws {
        let credentials = try LumixWiFiCredentials(ssid: "  GM1S-MANUAL  ", password: "", isWEP: false)

        XCTAssertEqual(credentials.ssid, "GM1S-MANUAL")
        XCTAssertNil(credentials.password)
    }

    func testRememberedCameraNetworkRoundTripsThroughKeychain() throws {
        let store = KeychainCameraNetworkStore(
            service: "com.web3.gm1sync.tests.\(UUID().uuidString)",
            account: "remembered-camera"
        )
        try? store.remove()
        defer { try? store.remove() }
        let credentials = try LumixWiFiCredentials(
            ssid: "GM1S-90C7E0",
            password: "camera-secret",
            isWEP: false
        )
        let network = RememberedCameraNetwork(credentials: credentials)

        try store.save(network)

        XCTAssertEqual(try store.load(), network)
        XCTAssertEqual(try store.load()?.credentials.ssid, "GM1S-90C7E0")
        try store.remove()
        XCTAssertNil(try store.load())
    }

    func testGroupsProfilesIntoStableCameraPhoto() throws {
        let itemID = "1280475"
        let resources = try ["CAM_RAW", "CAM_TN", "CAM_RAW_JPG", "CAM_LRGTN"].map { profile in
            LumixResource(
                itemID: itemID,
                title: "128-0475",
                url: try XCTUnwrap(URL(string: "http://192.168.54.1:50001/\(profile).jpg")),
                protocolInfo: "http-get:*:image/jpeg;PANASONIC.COM_PN=\(profile)"
            )
        }

        let photos = LumixPhoto.grouped(from: resources)
        let photo = try XCTUnwrap(photos.first)

        XCTAssertEqual(photos.count, 1)
        XCTAssertEqual(photo.id, "item:\(itemID)")
        XCTAssertEqual(photo.thumbnailResource?.profileName, "CAM_TN")
        XCTAssertEqual(photo.previewResource?.profileName, "CAM_LRGTN")
        XCTAssertEqual(photo.originalJPEGResource?.profileName, "CAM_RAW_JPG")
        XCTAssertEqual(photo.rawResource?.profileName, "CAM_RAW")
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

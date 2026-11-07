import Foundation
import XCTest
@testable import GM1Sync

final class CameraGeotagProtocolTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func sample(_ iso: String, _ latitude: Double, _ longitude: Double, altitude: Double = 0, accuracy: Double = 10) -> LocationSample {
        LocationSample(timestamp: date(iso), latitude: latitude, longitude: longitude, altitude: altitude, horizontalAccuracy: accuracy)
    }

    private func littleEndianInt32(_ data: Data, _ offset: Int) -> Int32 {
        let bytes = [UInt8](data)
        return Int32(bitPattern: UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24)
    }

    func testRecordsAreLittleEndianGPSEpochSecondsWithAStopMarker() throws {
        let fix = sample("2026-10-21T12:34:56Z", 35.6595, -139.7005, altitude: 40.7)
        let payload = try LumixGeodata.encode(try LumixGeodata.records(for: [fix]))

        XCTAssertEqual(payload.count, 8 + 2 * 16)
        XCTAssertEqual([UInt8](payload.prefix(8)), [1, 0, 0, 0, 2, 0, 0, 0])
        let expectedSeconds = Int32(date("2026-10-21T12:34:56Z").timeIntervalSince1970) - 315_964_800
        XCTAssertEqual(littleEndianInt32(payload, 8), expectedSeconds)
        XCTAssertEqual(littleEndianInt32(payload, 12), 356_595_000)
        XCTAssertEqual(littleEndianInt32(payload, 16), -1_397_005_000)
        XCTAssertEqual([UInt8](payload[20...23]), [40, 0, 65, 0], "Altitude 40 m, 'A', padding")

        XCTAssertEqual(littleEndianInt32(payload, 24), expectedSeconds + 1, "The stop marker follows one second later")
        XCTAssertEqual(littleEndianInt32(payload, 28), Int32.max)
        XCTAssertEqual(littleEndianInt32(payload, 32), Int32.max)
        XCTAssertEqual([UInt8](payload[36...39]), [0xFF, 0x7F, 86, 0], "No altitude (32767), 'V', padding")

        // 1980-01-06T00:00:00Z is second zero of the GPS epoch, without leap seconds.
        XCTAssertEqual(try LumixGeodata.gpsSeconds(for: date("1980-01-06T00:00:00Z")), 0)
        XCTAssertEqual(try LumixGeodata.gpsSeconds(for: date("1980-01-06T00:00:01Z")), 1)
    }

    func testCoordinatesTruncateTowardZeroAndAltitudeIsClamped() throws {
        let north = try LumixGeodata.record(for: sample("2026-01-01T00:00:00Z", 1.234_567_89, -2.5, altitude: 12.9))
        XCTAssertEqual(north.latitudeE7, 12_345_678)
        XCTAssertEqual(north.longitudeE7, -25_000_000)
        XCTAssertEqual(north.altitude, 12)
        let south = try LumixGeodata.record(for: sample("2026-01-01T00:00:00Z", -1.234_567_89, 179.999_999_99, altitude: -12.9))
        XCTAssertEqual(south.latitudeE7, -12_345_678)
        XCTAssertEqual(south.longitudeE7, 1_799_999_999)
        XCTAssertEqual(south.altitude, -12)

        XCTAssertEqual(LumixGeodata.altitude(40_000), 32_766, "32767 stays reserved for no altitude")
        XCTAssertEqual(LumixGeodata.altitude(-40_000), Int16.min)
        XCTAssertEqual(LumixGeodata.altitude(.nan), 0, "Image App writes 0 when altitude is unknown")
        XCTAssertEqual(LumixGeodata.altitude(0), 0)
    }

    func testGapsSplitTheTrackIntoSegmentsEachEndingWithAStopMarker() throws {
        let samples = [
            sample("2026-10-21T10:00:00Z", 1, 1),
            sample("2026-10-21T10:01:00Z", 1.001, 1.001),
            sample("2026-10-21T10:17:01Z", 1.002, 1.002),
            sample("2026-10-21T10:18:00Z", 1.003, 1.003)
        ]
        let records = try LumixGeodata.records(for: samples)
        XCTAssertEqual(records.map(\.flag), [65, 65, 86, 65, 65, 86])
        XCTAssertEqual(records[2].date, date("2026-10-21T10:01:01Z"))
        XCTAssertEqual(records[5].date, date("2026-10-21T10:18:01Z"))
        XCTAssertEqual(LumixGeodata.segments(of: samples).count, 2)

        let exactlyFifteenMinutes = [sample("2026-10-21T10:00:00Z", 1, 1), sample("2026-10-21T10:15:00Z", 1, 1)]
        XCTAssertEqual(LumixGeodata.segments(of: exactlyFifteenMinutes).count, 1)
    }

    func testOnlyUsableSamplesInsideThePeriodAreUploaded() throws {
        let samples = [
            sample("2026-10-21T09:59:59Z", 1, 1),
            sample("2026-10-21T10:00:00Z", 1, 1),
            sample("2026-10-21T10:00:00Z", 2, 2),
            sample("2026-10-21T10:01:00Z", 1, 1, accuracy: 900),
            sample("2026-10-21T10:02:00Z", 95, 1),
            sample("2026-10-21T10:03:00Z", 1, .infinity),
            sample("2026-10-21T10:04:00Z", 1.5, 1.5)
        ]
        let period = date("2026-10-21T10:00:00Z")...date("2026-10-21T10:30:00Z")
        let usable = LumixGeodata.usableSamples(samples, in: period)
        XCTAssertEqual(usable.map(\.timestamp), [date("2026-10-21T10:00:00Z"), date("2026-10-21T10:04:00Z")])
        let selection = try CameraGeodataSelection(samples: samples, period: period)
        XCTAssertEqual(selection.sampleCount, 2)
        XCTAssertEqual(selection.segmentCount, 1)
        XCTAssertEqual(selection.records.count, 3)
        XCTAssertEqual(try LumixGeodata.decode(selection.payload), selection.records)

        XCTAssertThrowsError(try CameraGeodataSelection(samples: samples, period: date("2027-01-01T00:00:00Z")...date("2027-01-02T00:00:00Z"))) { error in
            XCTAssertEqual(error as? LumixGeodata.EncodingError, .noSamples)
        }
    }

    func testRejectsUnstorableTimesMalformedPayloadsAndOversizedTracks() throws {
        XCTAssertThrowsError(try LumixGeodata.record(for: sample("1979-12-31T00:00:00Z", 1, 1))) { error in
            XCTAssertEqual(error as? LumixGeodata.EncodingError, .timestampOutOfRange)
        }
        XCTAssertThrowsError(try LumixGeodata.decode(Data([1, 0, 0, 0, 2, 0, 0, 0]))) { error in
            XCTAssertEqual(error as? LumixGeodata.EncodingError, .malformedPayload)
        }
        let record = LumixGeodata.Record(gpsSeconds: 1, latitudeE7: 1, longitudeE7: 1, altitude: 0, flag: 65)
        XCTAssertThrowsError(try LumixGeodata.encode(Array(repeating: record, count: LumixGeodata.maximumRecords + 1))) { error in
            XCTAssertEqual(error as? LumixGeodata.EncodingError, .tooManyRecords(LumixGeodata.maximumRecords + 1))
        }
    }

    func testMultipartBodyMatchesImageAppFramingByteForByte() {
        let body = LumixGeodataUpload.body(for: Data([0x01, 0x02, 0x03]))
        let expected = Data((
            "--xyzxyz\r\nContent-Disposition: form-data; name=\"filename\"; filename=\"bindata.bin\"\r\n" +
                "Content-Type: application/octet-stream\r\nContent-Transfer-Encoding: binary\r\n" +
                "Content-Length: 3\r\n\r\n"
        ).utf8) + Data([0x01, 0x02, 0x03]) + Data("--xyzxyz--".utf8)
        XCTAssertEqual(body, expected)
        XCTAssertEqual(LumixGeodataUpload.contentType, "multipart/form-data; boundary=xyzxyz")
        XCTAssertEqual(DemoGeotagCamera.payload(in: body), Data([0x01, 0x02, 0x03]))
    }

    func testClockValuesUseUTCFieldsAndTheStandardOffset() throws {
        let instant = date("2026-10-21T12:34:56Z")
        XCTAssertEqual(try LumixCameraClock.value(for: instant, offsetMinutes: 420), "20261021123456+0700")
        XCTAssertEqual(try LumixCameraClock.value(for: instant, offsetMinutes: -330), "20261021123456-0530")
        XCTAssertEqual(try LumixCameraClock.value(for: instant, offsetMinutes: 0), "20261021123456+0000")
        XCTAssertThrowsError(try LumixCameraClock.value(for: instant, offsetMinutes: 900))

        let summer = date("2026-07-01T12:00:00Z")
        let winter = date("2026-01-15T12:00:00Z")
        XCTAssertEqual(LumixCameraClock.rawOffsetMinutes(of: TimeZone(identifier: "Europe/Berlin")!, at: summer), 60,
                       "Daylight saving is not included, like Java's getRawOffset()")
        XCTAssertEqual(LumixCameraClock.rawOffsetMinutes(of: TimeZone(identifier: "Europe/Berlin")!, at: winter), 60)
        XCTAssertEqual(LumixCameraClock.rawOffsetMinutes(of: TimeZone(identifier: "America/New_York")!, at: summer), -300)
        XCTAssertEqual(LumixCameraClock.rawOffsetMinutes(of: TimeZone(identifier: "Asia/Kolkata")!, at: summer), 330)
        XCTAssertEqual(LumixCameraClock.rawOffsetMinutes(of: TimeZone(identifier: "Australia/Adelaide")!, at: winter), 570)
        XCTAssertEqual(try LumixCameraClock.value(for: summer, timeZone: TimeZone(identifier: "Europe/Berlin")!),
                       "20260701120000+0100")
    }

    func testNextMinuteBoundaryIsAlwaysAheadAndWhole() {
        XCTAssertEqual(LumixCameraClock.nextMinuteBoundary(after: date("2026-10-21T12:34:56Z").addingTimeInterval(0.4)),
                       date("2026-10-21T12:35:00Z"))
        XCTAssertEqual(LumixCameraClock.nextMinuteBoundary(after: date("2026-10-21T12:35:00Z")),
                       date("2026-10-21T12:36:00Z"))
    }

    func testClockQueriesEncodePlusAndKeepTheRawFallback() {
        XCTAssertEqual(LumixCameraClock.percentEncodedQuery(mode: "notify", type: "clock", value: "20261021123456+0700", encodePlus: true),
                       "mode=notify&type=clock&value=20261021123456%2B0700")
        XCTAssertEqual(LumixCameraClock.percentEncodedQuery(mode: "notify", type: "clock", value: "20261021123456+0700", encodePlus: false),
                       "mode=notify&type=clock&value=20261021123456+0700")
        XCTAssertEqual(LumixCameraClock.percentEncodedQuery(mode: "setsetting", type: "clock", value: "20261021123456-0530", encodePlus: true),
                       "mode=setsetting&type=clock&value=20261021123456-0530")
    }

    func testClockReadingKeepsRawTextAndRejectsImpossibleDates() throws {
        let reading = try XCTUnwrap(LumixCameraClockReading(reply: LumixCommandReply.parse(
            "<camrply><result>ok</result><settingvalue clock=\"20261021123456+0700\"></settingvalue></camrply>"
        )))
        XCTAssertEqual(reading.raw, "20261021123456+0700")
        XCTAssertEqual(reading.utcDate, date("2026-10-21T12:34:56Z"))
        XCTAssertEqual(reading.offsetMinutes, 420)
        XCTAssertEqual(try XCTUnwrap(reading.difference(from: date("2026-10-21T12:34:50Z"))), 6, accuracy: 0.001)

        XCTAssertEqual(LumixCameraClockReading(raw: "20261021123456-0530").offsetMinutes, -330)
        XCTAssertNil(LumixCameraClockReading(raw: "20261321123456").utcDate, "Month 13 is not rolled over")
        let unknown = LumixCameraClockReading(raw: "2026/10/21 12:34")
        XCTAssertNil(unknown.utcDate)
        XCTAssertEqual(unknown.raw, "2026/10/21 12:34")
        XCTAssertEqual(LumixCameraClockReading(reply: LumixCommandReply.parse("ok,20261021123456"))?.utcDate,
                       date("2026-10-21T12:34:56Z"))
        XCTAssertNil(LumixCameraClockReading(reply: LumixCommandReply.parse("<camrply><result>err_param</result></camrply>")))
    }

    func testProgressAndUploadAnnouncementReplies() {
        let finished = LumixLocationWriteProgress(reply: LumixCommandReply.parse(
            "<camrply><result>ok</result><state>finish</state><progress>100</progress><err></err></camrply>"
        ))
        XCTAssertEqual(finished.state, .finish)
        XCTAssertEqual(finished.progress, 100)
        XCTAssertNil(finished.error)

        let cancelled = LumixLocationWriteProgress(reply: LumixCommandReply.parse(
            "<camrply><result>ok</result><state>error</state><progress>40</progress><err>cancel</err></camrply>"
        ))
        XCTAssertTrue(cancelled.isCancelled)
        XCTAssertEqual(LumixLocationWriteProgress(reply: LumixCommandReply.parse(
            "<camrply><result>ok</result><state>Exec</state></camrply>"
        )).state, .exec)
        XCTAssertEqual(LumixLocationWriteProgress(reply: LumixCommandReply.parse(
            "<camrply><result>ok</result><state>waiting</state></camrply>"
        )).state, .unknown)
        XCTAssertEqual(LumixLocationWriteProgress(reply: LumixCommandReply.parse(
            "<camrply><result>err_busy</result></camrply>"
        )).result, LumixResultCode.busy)

        XCTAssertTrue(LumixGeodataReplies.acceptsSingleUpload(LumixCommandReply.parse(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n<camrply><result>ok</result><method>once</method></camrply>"
        )))
        XCTAssertFalse(LumixGeodataReplies.acceptsSingleUpload(LumixCommandReply.parse("<camrply><result>ok</result></camrply>")))
        XCTAssertFalse(LumixGeodataReplies.acceptsSingleUpload(LumixCommandReply.parse(
            "<camrply><result>err_param</result><method>once</method></camrply>"
        )))
    }

    func testCapabilityGateFollowsImageAppAndPanasonicDocumentation() {
        func capabilities(version: String? = nil, model: String? = nil, specs: Set<String> = []) -> CameraCapabilities {
            CameraCapabilities(model: nil, version: nil, date: nil, entries: [],
                               protocolVersion: version, productModelName: model, specs: specs)
        }
        XCTAssertEqual(CameraLocationWriteSupport.evaluate(nil), .unknown)
        XCTAssertTrue(CameraLocationWriteSupport.evaluate(capabilities(specs: ["geotag_add_enable"])).isSupported)
        XCTAssertTrue(CameraLocationWriteSupport.evaluate(capabilities(version: "1.6")).isSupported)
        XCTAssertTrue(CameraLocationWriteSupport.evaluate(capabilities(version: "1.10")).isSupported)
        XCTAssertFalse(CameraLocationWriteSupport.evaluate(capabilities(version: "1.2", model: "GM1")).isSupported)
        guard case let .supported(evidence) = CameraLocationWriteSupport.evaluate(capabilities(version: "1.2", model: "DMC-GM1S")) else {
            return XCTFail("Panasonic documents app-triggered writing for the GM1S")
        }
        XCTAssertTrue(evidence.contains("GM1S"))
        XCTAssertFalse(CameraLocationWriteSupport.evaluate(capabilities()).isSupported)
    }
}

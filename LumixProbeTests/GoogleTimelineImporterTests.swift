import XCTest
@testable import GM1Sync

final class GoogleTimelineImporterTests: XCTestCase {
    func testImportsCurrentIOSVisitAndActivityRecords() throws {
        let data = Data(#"""
        [
          {
            "startTime": "2026-08-23T10:00:00.000Z",
            "endTime": "2026-08-23T10:30:00.000Z",
            "visit": {
              "topCandidate": {
                "placeLocation": "geo:1.500000,103.500000"
              }
            }
          },
          {
            "startTime": "2026-08-23T10:31:00.000Z",
            "endTime": "2026-08-23T11:00:00.000Z",
            "activity": {
              "start": "geo:1.510000,103.510000",
              "end": "geo:1.600000,103.600000"
            }
          }
        ]
        """#.utf8)

        let samples = try GoogleTimelineImporter.samples(from: data)

        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[0].timestamp, date("2026-08-23T10:00:00.000Z"))
        XCTAssertEqual(samples[0].latitude, 1.5, accuracy: 0.000001)
        XCTAssertEqual(samples[0].longitude, 103.5, accuracy: 0.000001)
        XCTAssertEqual(samples[0].horizontalAccuracy, GoogleTimelineImporter.estimatedHorizontalAccuracy)
        XCTAssertEqual(samples[3].latitude, 1.6, accuracy: 0.000001)
        XCTAssertEqual(samples[3].longitude, 103.6, accuracy: 0.000001)
    }

    func testImportsSemanticSegmentsTimelinePath() throws {
        let data = Data(#"""
        {
          "semanticSegments": [
            {
              "startTime": "2026-08-23T12:00:00Z",
              "timelinePath": [
                { "point": "geo:1.000000,103.000000", "durationMinutesOffsetFromStartTime": "0" },
                { "point": "geo:1.100000,103.100000", "durationMinutesOffsetFromStartTime": "5" }
              ]
            }
          ]
        }
        """#.utf8)

        let samples = try GoogleTimelineImporter.samples(from: data)

        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[1].timestamp, date("2026-08-23T12:05:00Z"))
        XCTAssertEqual(samples[1].latitude, 1.1, accuracy: 0.000001)
        XCTAssertEqual(samples[1].longitude, 103.1, accuracy: 0.000001)
    }

    func testImportsJSONStringCopiedToClipboard() throws {
        let text = #"""
        [
          {
            "startTime": "2026-08-23T13:00:00Z",
            "endTime": "2026-08-23T13:05:00Z",
            "activity": {
              "start": "geo:1.200000,103.200000",
              "end": "geo:1.210000,103.210000"
            }
          }
        ]
        """#

        let samples = try GoogleTimelineImporter.samples(from: text)

        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[1].latitude, 1.21, accuracy: 0.000001)
        XCTAssertEqual(samples[1].longitude, 103.21, accuracy: 0.000001)
    }

    func testImportsLegacyLocationsWithE7CoordinatesAndAccuracy() throws {
        let data = Data(#"""
        {
          "locations": [
            {
              "timestampMs": "1000000000000",
              "latitudeE7": 12345678,
              "longitudeE7": 1038765432,
              "accuracy": 18
            }
          ]
        }
        """#.utf8)

        let samples = try GoogleTimelineImporter.samples(from: data)

        let sample = try XCTUnwrap(samples.first)
        XCTAssertEqual(sample.timestamp, Date(timeIntervalSince1970: 1_000_000_000))
        XCTAssertEqual(sample.latitude, 1.2345678, accuracy: 0.0000001)
        XCTAssertEqual(sample.longitude, 103.8765432, accuracy: 0.0000001)
        XCTAssertEqual(sample.horizontalAccuracy, 18)
    }

    func testImportsLegacyTimelineObjects() throws {
        let data = Data(#"""
        {
          "timelineObjects": [
            {
              "placeVisit": {
                "location": { "latitudeE7": 12345678, "longitudeE7": 1038765432 },
                "duration": {
                  "startTimestampMs": "1000000000000",
                  "endTimestampMs": "1000000060000"
                }
              }
            },
            {
              "activitySegment": {
                "startLocation": { "latitudeE7": 12500000, "longitudeE7": 1039000000 },
                "endLocation": { "latitudeE7": 13000000, "longitudeE7": 1040000000 },
                "duration": {
                  "startTimestampMs": "1000000060000",
                  "endTimestampMs": "1000000120000"
                }
              }
            }
          ]
        }
        """#.utf8)

        let samples = try GoogleTimelineImporter.samples(from: data)

        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[0].latitude, 1.2345678, accuracy: 0.0000001)
        XCTAssertEqual(samples[3].latitude, 1.3, accuracy: 0.0000001)
        XCTAssertEqual(samples[3].longitude, 104, accuracy: 0.0000001)
    }

    func testRejectsInvalidOrLocationFreeJSON() {
        XCTAssertThrowsError(try GoogleTimelineImporter.samples(from: Data("not json".utf8))) { error in
            XCTAssertEqual(error as? GoogleTimelineImporter.ImportError, .invalidJSON)
        }

        XCTAssertThrowsError(try GoogleTimelineImporter.samples(from: Data("[]".utf8))) { error in
            XCTAssertEqual(error as? GoogleTimelineImporter.ImportError, .noUsableLocations)
        }
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)!
    }
}

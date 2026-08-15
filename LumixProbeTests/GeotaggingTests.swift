import CoreLocation
import XCTest
@testable import GM1Sync

final class GeotaggingTests: XCTestCase {
    func testInterpolatesLocationAroundCaptureTime() throws {
        let capture = Date(timeIntervalSince1970: 1_000)
        let samples = [
            sample(at: 990, latitude: 1, longitude: 100, accuracy: 12),
            sample(at: 1_010, latitude: 3, longitude: 104, accuracy: 18)
        ]

        let match = try XCTUnwrap(LocationTrackMatcher.match(captureDate: capture, samples: samples))

        XCTAssertEqual(match.method, .interpolated)
        XCTAssertEqual(match.latitude, 2, accuracy: 0.000_001)
        XCTAssertEqual(match.longitude, 102, accuracy: 0.000_001)
        XCTAssertEqual(match.horizontalAccuracy, 18)
        XCTAssertEqual(match.quality, .excellent)
    }

    func testAppliesCameraClockAdjustmentBeforeMatching() throws {
        let capture = Date(timeIntervalSince1970: 1_000)
        let samples = [sample(at: 1_120, latitude: 1.25, longitude: 103.8, accuracy: 20)]

        let match = try XCTUnwrap(LocationTrackMatcher.match(
            captureDate: capture,
            samples: samples,
            cameraClockOffset: 120
        ))

        XCTAssertEqual(match.method, .nearest)
        XCTAssertEqual(match.nearestSampleTimeDifference, 0)
        XCTAssertEqual(match.adjustedCaptureDate, samples[0].timestamp)
    }

    func testRejectsTrackPointOutsideMaximumTimeDifference() {
        let capture = Date(timeIntervalSince1970: 10_000)
        let samples = [sample(at: 1_000, latitude: 1, longitude: 2, accuracy: 10)]

        XCTAssertNil(LocationTrackMatcher.match(
            captureDate: capture,
            samples: samples,
            maximumTimeDifference: 60
        ))
    }

    func testRejectsUnusableAccuracy() {
        let capture = Date(timeIntervalSince1970: 1_000)
        let samples = [sample(at: 1_000, latitude: 1, longitude: 2, accuracy: 900)]

        XCTAssertNil(LocationTrackMatcher.match(captureDate: capture, samples: samples))
    }

    func testParsesExifDateUsingExplicitOffset() throws {
        let parsed = try XCTUnwrap(PhotoCaptureDateReader.parse(
            "2026:08:14 15:30:00",
            offset: "+08:00",
            fallbackTimeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        ))

        XCTAssertEqual(parsed.timeIntervalSince1970, 1_786_692_600, accuracy: 0.1)
    }

    func testParsesExifDateUsingFallbackTimeZone() throws {
        let singapore = try XCTUnwrap(TimeZone(identifier: "Asia/Singapore"))
        let parsed = try XCTUnwrap(PhotoCaptureDateReader.parse(
            "2026:08:14 15:30:00",
            offset: nil,
            fallbackTimeZone: singapore
        ))

        XCTAssertEqual(parsed.timeIntervalSince1970, 1_786_692_600, accuracy: 0.1)
    }

    @MainActor
    func testAutoStartGeotaggingPreferenceLoadsAndPersists() {
        let suiteName = "GeotaggingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "autoStartGeotagging")

        let model = ProbeViewModel(
            defaults: defaults,
            cameraNetworkStore: EmptyCameraNetworkStore()
        )

        XCTAssertTrue(model.autoStartGeotagging)
        model.autoStartGeotagging = false
        XCTAssertFalse(defaults.bool(forKey: "autoStartGeotagging"))
    }

    private func sample(
        at timestamp: TimeInterval,
        latitude: Double,
        longitude: Double,
        accuracy: Double
    ) -> LocationSample {
        LocationSample(
            timestamp: Date(timeIntervalSince1970: timestamp),
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: accuracy
        )
    }
}

private struct EmptyCameraNetworkStore: CameraNetworkStoring {
    func load() throws -> RememberedCameraNetwork? { nil }
    func save(_ network: RememberedCameraNetwork) throws {}
    func remove() throws {}
}

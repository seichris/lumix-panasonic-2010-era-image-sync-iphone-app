import Foundation
import XCTest
@testable import GM1Sync

@MainActor
final class CameraGeotagVerificationTests: XCTestCase {
    private let start = ISO8601DateFormatter().date(from: "2026-10-21T10:00:00Z")!
    private lazy var period = start...start.addingTimeInterval(3600)
    private lazy var track = [
        LocationSample(timestamp: start, latitude: 35.0, longitude: 139.0, horizontalAccuracy: 8),
        LocationSample(timestamp: start.addingTimeInterval(600), latitude: 35.01, longitude: 139.0, horizontalAccuracy: 8)
    ]

    private func photo(_ id: String) -> LumixPhoto {
        LumixPhoto(itemID: id, title: id, resources: [
            LumixResource(itemID: id, title: id, url: URL(string: "http://192.168.54.1:50001/DO\(id).JPG")!,
                          protocolInfo: "http-get:*:image/jpeg;PANASONIC.COM_PN=CAM_ORG")
        ])
    }

    private func inspected(_ captureDate: Date?, _ location: PhotoGeotagLocation?) -> CameraPhotoMetadataInspectionState {
        .resolved(CameraPhotoMetadataInspection(
            galleryCaptureDate: nil, itemMetadataCaptureDate: nil, exifCaptureDate: captureDate,
            embeddedLocation: location, itemMetadataError: nil
        ))
    }

    private func status(
        _ state: CameraPhotoMetadataInspectionState,
        baseline: [LumixPhoto.ID: PhotoGeotagLocation?] = [:]
    ) -> CameraGeotagVerificationResult.Status {
        CameraGeotagVerifier.classify(photo("1"), state: state, period: period, trackSamples: track, baseline: baseline).status
    }

    func testPhotosInsideThePeriodAreComparedWithTheTrack() {
        let midway = start.addingTimeInterval(300)
        guard case let .taggedNearTrack(distance) = status(inspected(midway, PhotoGeotagLocation(latitude: 35.005, longitude: 139.0))) else {
            return XCTFail("A position on the interpolated track is near it")
        }
        XCTAssertLessThan(distance, 5)
        guard case .taggedFarFromTrack = status(inspected(midway, PhotoGeotagLocation(latitude: 36, longitude: 139))) else {
            return XCTFail("A distant position is flagged")
        }
        XCTAssertEqual(status(inspected(midway, nil)), .notTagged)
        XCTAssertEqual(status(inspected(start.addingTimeInterval(3000), PhotoGeotagLocation(latitude: 35, longitude: 139))),
                       .taggedWithoutTrackPosition, "No track position within 15 minutes to compare with")
    }

    func testPhotosOutsideThePeriodAndAlreadyGeotaggedPhotos() {
        let outside = start.addingTimeInterval(-600)
        XCTAssertEqual(status(inspected(outside, nil)), .outsidePeriodUntouched)
        XCTAssertEqual(status(inspected(outside, PhotoGeotagLocation(latitude: 1, longitude: 1))), .outsidePeriodTagged)

        let before = PhotoGeotagLocation(latitude: 48.0, longitude: 11.0)
        XCTAssertEqual(status(inspected(start.addingTimeInterval(300), before), baseline: [photo("1").id: before]),
                       .alreadyTaggedUnchanged)
        XCTAssertEqual(status(inspected(start.addingTimeInterval(300), PhotoGeotagLocation(latitude: 35.005, longitude: 139.0)),
                              baseline: [photo("1").id: before]),
                       .alreadyTaggedChanged)
        XCTAssertEqual(status(inspected(nil, PhotoGeotagLocation(latitude: 1, longitude: 1))), .unknownCaptureTime(hasLocation: true))
        XCTAssertEqual(status(.failed("timeout")), .failed("timeout"))
    }
}

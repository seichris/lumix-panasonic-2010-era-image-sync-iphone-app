import Foundation
import XCTest
@testable import GM1Sync

final class CameraLocationOverrideTests: XCTestCase {
    func testUserDefaultsStoreRoundTripsManualLocation() throws {
        let suiteName = "CameraLocationOverrideTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let location = PhotoGeotagLocation(
            latitude: 1.3521,
            longitude: 103.8198,
            altitude: 24,
            horizontalAccuracy: 15
        )
        let firstStore = UserDefaultsCameraLocationOverrideStore(defaults: defaults)
        try firstStore.save(["camera|photo": location])

        let reloadedStore = UserDefaultsCameraLocationOverrideStore(defaults: defaults)
        XCTAssertEqual(try reloadedStore.load()["camera|photo"], location)
    }
}

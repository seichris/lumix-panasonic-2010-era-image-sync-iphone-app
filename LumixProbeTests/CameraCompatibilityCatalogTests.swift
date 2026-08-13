import XCTest
@testable import GM1Sync

final class CameraCompatibilityCatalogTests: XCTestCase {
    func testCatalogIncludesPrimaryGMFamily() {
        let models = CameraCompatibilityCatalog.allCameras.map(\.models)

        XCTAssertTrue(models.contains("Panasonic DMC-GM1"))
        XCTAssertTrue(models.contains("Panasonic DMC-GM1S"))
        XCTAssertTrue(models.contains("Panasonic DMC-GM5"))
    }

    func testEveryCandidateHasUniqueModelsAndAnEra() {
        let cameras = CameraCompatibilityCatalog.allCameras

        XCTAssertEqual(Set(cameras.map(\.models)).count, cameras.count)
        XCTAssertTrue(cameras.allSatisfy { !$0.modelEra.isEmpty })
    }
}

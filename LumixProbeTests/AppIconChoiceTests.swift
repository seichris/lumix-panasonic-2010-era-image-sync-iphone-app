import XCTest
@testable import GM1Sync

final class AppIconChoiceTests: XCTestCase {
    func testAlternateIconNamesMatchAssetCatalogNames() {
        XCTAssertNil(AppIconChoice.primary.alternateIconName)
        XCTAssertEqual(AppIconChoice.lens.alternateIconName, "AppIcon")
        XCTAssertEqual(AppIconChoice.blackCamera.alternateIconName, "BlackCamera")
        XCTAssertEqual(AppIconChoice.primary.title, "Blue Camera")
        XCTAssertEqual(AppIconChoice.primary.previewAssetName, "BlueCameraIconPreview")
    }

    func testEveryChoiceHasAUniquePreview() {
        let previewNames = AppIconChoice.allCases.map(\.previewAssetName)

        XCTAssertEqual(Set(previewNames).count, AppIconChoice.allCases.count)
    }
}

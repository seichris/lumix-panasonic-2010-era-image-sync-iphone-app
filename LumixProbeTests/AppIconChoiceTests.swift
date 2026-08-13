import XCTest
@testable import GM1Sync

final class AppIconChoiceTests: XCTestCase {
    func testAlternateIconNamesMatchAssetCatalogNames() {
        XCTAssertNil(AppIconChoice.primary.alternateIconName)
        XCTAssertEqual(AppIconChoice.blueCamera.alternateIconName, "BlueCamera")
        XCTAssertEqual(AppIconChoice.blackCamera.alternateIconName, "BlackCamera")
    }

    func testEveryChoiceHasAUniquePreview() {
        let previewNames = AppIconChoice.allCases.map(\.previewAssetName)

        XCTAssertEqual(Set(previewNames).count, AppIconChoice.allCases.count)
    }
}

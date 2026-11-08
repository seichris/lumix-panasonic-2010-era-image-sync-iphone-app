import XCTest
#if os(iOS)
import UIKit
#endif
@testable import GM1Sync

final class AppIconChoiceTests: XCTestCase {
    func testAlternateIconNamesMatchAssetCatalogNames() {
        XCTAssertNil(AppIconChoice.primary.alternateIconName)
        XCTAssertEqual(AppIconChoice.lens.alternateIconName, "AppIcon")
        XCTAssertEqual(AppIconChoice.blackCamera.alternateIconName, "BlackCamera")
        XCTAssertEqual(AppIconChoice.gm1sOrange.alternateIconName, "GM1SOrange")
        XCTAssertEqual(AppIconChoice.fz1000.alternateIconName, "FZ1000")
        XCTAssertEqual(AppIconChoice.primary.title, "Blue Camera")
        XCTAssertEqual(AppIconChoice.g85.title, "G85 / G80")
        XCTAssertEqual(AppIconChoice.primary.previewAssetName, "BlueCameraIconPreview")
        XCTAssertEqual(AppIconChoice.gx85.previewAssetName, "GX85IconPreview")
    }

    func testEveryChoiceHasAUniquePreview() {
        let previewNames = AppIconChoice.allCases.map(\.previewAssetName)

        XCTAssertEqual(Set(previewNames).count, AppIconChoice.allCases.count)
    }

    func testOnlyLensAndBlackCameraWereFreeBefore() {
        XCTAssertEqual(AppIconChoice.allCases.filter(\.wasFreeBefore), [.lens, .blackCamera])
    }

#if os(iOS)
    /// Every choice has its preview image and, except Blue Camera, an alternate icon the
    /// build registered (from `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`).
    func testEveryChoiceIsInTheAppBundle() throws {
        let icons = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let alternates = try XCTUnwrap(icons["CFBundleAlternateIcons"] as? [String: Any])
        for icon in AppIconChoice.allCases {
            XCTAssertNotNil(UIImage(named: icon.previewAssetName), "Missing preview for \(icon.title)")
            if let name = icon.alternateIconName {
                XCTAssertNotNil(alternates[name], "Missing alternate icon \(name)")
            }
        }
    }
#endif
}

import UIKit
import XCTest
@testable import GM1Sync

final class DemoCameraGalleryClientTests: XCTestCase {
    func testFixtureRendersOpaqueSyntheticJPEGs() async throws {
        let client = DemoCameraGalleryClient(total: 2)
        let first = try XCTUnwrap(DemoCameraGalleryClient.photo(0).thumbnailResource)
        let second = try XCTUnwrap(DemoCameraGalleryClient.photo(1).thumbnailResource)

        let firstData = try await client.downloadJPEGData(first)
        let secondData = try await client.downloadJPEGData(second)

        XCTAssertEqual(Array(firstData.prefix(2)), [0xFF, 0xD8])
        XCTAssertEqual(Array(secondData.prefix(2)), [0xFF, 0xD8])
        XCTAssertNotEqual(firstData, secondData)

        let firstImage = try XCTUnwrap(UIImage(data: firstData))
        XCTAssertEqual(firstImage.size, CGSize(width: 1_200, height: 900))
    }
}

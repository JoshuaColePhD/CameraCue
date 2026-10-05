import XCTest
import AppKit
@testable import TeleprompterApp

@MainActor final class CameraCueLogoTests: XCTestCase {
    func testLogoRetainsOriginalHighResolutionArtwork() {
        XCTAssertTrue(CameraCueMark.image.representations.contains { $0.pixelsWide >= 1024 && $0.pixelsHigh >= 1024 }, "\(CameraCueMark.image.representations)")
        XCTAssertFalse(CameraCueMark.image.isTemplate)
    }

    func testNotchImagesContainSharpScaleRepresentationsAndTransparentPadding() throws {
        for (image, width) in [(CameraCueMark.leadingImage, 72), (CameraCueMark.expandedImage, 32)] {
            for scale in [1, 2, 3] {
                let rep = try XCTUnwrap(image.representations.compactMap { $0 as? NSBitmapImageRep }
                    .first { $0.pixelsWide == width * scale && $0.pixelsHigh == 22 * scale })
                XCTAssertEqual(try XCTUnwrap(rep.colorAt(x: 0, y: 11 * scale)).alphaComponent, 0)
                XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x: 20 * scale, y: 11 * scale)).alphaComponent, 0.9)
            }
        }
    }
}

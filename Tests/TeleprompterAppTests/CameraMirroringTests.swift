import XCTest
@testable import TeleprompterApp

final class CameraMirroringTests: XCTestCase {
    func testPreviewDisablesAutomaticMirroringBeforeManualFlip() {
        let connection = MirroringFixture()
        CameraMirroring.apply(to: connection, mirrored: true)
        XCTAssertEqual(connection.events, ["automatic:false", "mirrored:true"])
        XCTAssertTrue(connection.isVideoMirrored)
        CameraMirroring.apply(to: connection, mirrored: true)
        XCTAssertEqual(connection.events.filter { $0 == "mirrored:true" }.count, 1)
    }
    func testSavedVideoDisablesAutomaticMirroringBeforeRemovingFlip() {
        let connection = MirroringFixture(mirrored: true)
        CameraMirroring.apply(to: connection, mirrored: false)
        XCTAssertEqual(connection.events, ["automatic:false", "mirrored:false"])
        XCTAssertFalse(connection.isVideoMirrored)
    }
    func testUnsupportedConnectionIsNeverMutated() {
        let connection = MirroringFixture(supported: false)
        CameraMirroring.apply(to: connection, mirrored: true)
        XCTAssertTrue(connection.events.isEmpty)
    }
}
private final class MirroringFixture: CameraMirroringConnection {
    var events: [String] = []
    let isVideoMirroringSupported: Bool
    var automaticallyAdjustsVideoMirroring = true {
        didSet { events.append("automatic:\(automaticallyAdjustsVideoMirroring)") }
    }
    var isVideoMirrored: Bool {
        didSet {
            XCTAssertFalse(automaticallyAdjustsVideoMirroring, "Manual mirroring would crash AVFoundation with automatic mirroring enabled")
            XCTAssertTrue(isVideoMirroringSupported)
            events.append("mirrored:\(isVideoMirrored)")
        }
    }
    init(supported: Bool = true, mirrored: Bool = false) {
        isVideoMirroringSupported = supported; isVideoMirrored = mirrored
    }
}

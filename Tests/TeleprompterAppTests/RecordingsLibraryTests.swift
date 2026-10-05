import XCTest
@testable import TeleprompterApp

final class RecordingsLibraryTests: XCTestCase {
    func testDiscoveryFindsExistingMP4sAcrossFoldersWithoutDuplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let one = first.appendingPathComponent("Café take.mp4")
        let two = second.appendingPathComponent("Another.MP4")
        try Data().write(to: one); try Data().write(to: two)
        try Data().write(to: first.appendingPathComponent("Original.mov"))
        try FileManager.default.createDirectory(at: first.appendingPathComponent("directory.mp4"), withIntermediateDirectories: true)
        let found = try RecordingDiscovery.scan(folders: [first, first, second, root.appendingPathComponent("missing")])
        XCTAssertEqual(Set(found.map { $0.url.resolvingSymlinksInPath() }), Set([one, two].map { $0.resolvingSymlinksInPath() }))
        XCTAssertEqual(found.count, 2)
    }
}

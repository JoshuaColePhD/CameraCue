import XCTest
@testable import TeleprompterCore

final class PresentationClockTests: XCTestCase {
    func testElapsedTimePausesAndResumesWithoutCountingTheBreak() {
        let start = Date(timeIntervalSince1970: 100)
        var clock = PresentationClock()
        clock.start(at: start)
        XCTAssertEqual(clock.elapsed(at: start.addingTimeInterval(12)), 12)
        clock.pause(at: start.addingTimeInterval(12))
        XCTAssertEqual(clock.elapsed(at: start.addingTimeInterval(50)), 12)
        clock.start(at: start.addingTimeInterval(50))
        XCTAssertEqual(clock.elapsed(at: start.addingTimeInterval(58)), 20)
        XCTAssertEqual(clock.display(at: start.addingTimeInterval(58)), "00:20")
        clock.reset()
        XCTAssertEqual(clock.elapsed(at: start.addingTimeInterval(100)), 0)
    }

    func testHourFormatting() {
        var clock = PresentationClock()
        let start = Date(timeIntervalSince1970: 0)
        clock.start(at: start)
        XCTAssertEqual(clock.display(at: start.addingTimeInterval(3_661)), "1:01:01")
    }

    func testCountdownPausesAndShowsNegativeOvertime() {
        let start = Date(timeIntervalSince1970: 100)
        var clock = PresentationClock()
        XCTAssertEqual(clock.countdownDisplay(duration: 60, at: start), "01:00")
        clock.start(at: start)
        clock.pause(at: start.addingTimeInterval(20))
        XCTAssertEqual(clock.countdownDisplay(duration: 60, at: start.addingTimeInterval(100)), "00:40")
        clock.start(at: start.addingTimeInterval(100))
        XCTAssertEqual(clock.countdownDisplay(duration: 60, at: start.addingTimeInterval(140)), "00:00")
        XCTAssertEqual(clock.countdownDisplay(duration: 60, at: start.addingTimeInterval(142)), "-00:02")
    }
}

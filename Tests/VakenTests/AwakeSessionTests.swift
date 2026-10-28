import XCTest
@testable import VakenCore

final class AwakeSessionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1000)
    let followOff = PolicyInput(mode: .followPowerSource, flag: false, isAC: true)

    func testManualOffDoesNotImmediatelyReenableFollow() {
        var session = AwakeSession()
        session.observePower(true)
        session.requestOff()
        XCTAssertEqual(session.action(followOff, now: now), .restoreSilently)
        session.restored()
        XCTAssertEqual(session.action(followOff, now: now), .none)
        session.observePower(nil)
        session.observePower(true)
        XCTAssertEqual(session.action(followOff, now: now), .none)
        session.observePower(false)
        session.observePower(true)
        XCTAssertEqual(session.action(followOff, now: now), .enableWithConsent)
    }

    func testFailedRestoreWaitsTenSecondsAndRetainsIntent() {
        var session = AwakeSession()
        session.requestOff()
        session.restoreFailed(now: now)
        XCTAssertEqual(session.action(followOff, now: now.addingTimeInterval(9)), .none)
        XCTAssertEqual(session.action(followOff, now: now.addingTimeInterval(10)), .restoreSilently)
    }

    func testExpiryRemainsPendingUntilOperationCanRun() {
        var session = AwakeSession()
        session.startTimer(.minutes30, now: now)
        session.tick(now: now.addingTimeInterval(1800))
        XCTAssertTrue(session.restorePending)
        XCTAssertTrue(session.paused)
        session.tick(now: now.addingTimeInterval(1810))
        XCTAssertEqual(session.action(followOff, now: now.addingTimeInterval(1810)), .restoreSilently)
        session.restored()
        XCTAssertEqual(session.action(followOff, now: now.addingTimeInterval(1810)), .none)
    }

    func testManualOnResumesAndRemovesOldTimer() {
        var session = AwakeSession()
        session.startTimer(.hour1, now: now)
        session.requestOff()
        session.requestOn()
        XCTAssertNil(session.deadline)
        XCTAssertFalse(session.paused)
        XCTAssertFalse(session.restorePending)
    }

    func testPauseNeverSuppressesBatteryRestore() {
        var session = AwakeSession()
        session.suppressConsent()
        XCTAssertEqual(session.action(.init(mode: .followPowerSource, flag: true, isAC: false), now: now), .restoreSilently)
    }
}

import XCTest
import VakenCore
@testable import vaken

final class UpdateTests: XCTestCase {
    func testSparkleCallbacksAreExposedToObjectiveC() {
        let updater = AppUpdater()
        for selector in [
            "updater:shouldProceedWithUpdate:updateCheck:error:",
            "updaterShouldRelaunchApplication:",
            "updater:didFinishUpdateCycleForUpdateCheck:error:",
            "updater:didAbortWithError:",
        ] {
            XCTAssertTrue(updater.responds(to: NSSelectorFromString(selector)), selector)
        }
    }
    func testConfigurationRequiresHTTPSAndCompleteSigningMetadata() throws {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        XCTAssertNil(try UpdateConfiguration(info: [:]))
        let valid: [String: Any] = ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": key, "CFBundleVersion": "1"]
        XCTAssertNotNil(try UpdateConfiguration(info: valid))
        for change: [String: Any] in [
            ["SUFeedURL": "http://example.com/appcast.xml"],
            ["SUFeedURL": "https://user:pass@example.com/feed"],
            ["SUPublicEDKey": "invalid"], ["CFBundleVersion": "0"],
            ["CFBundleVersion": "1.2"],
        ] {
            XCTAssertThrowsError(try UpdateConfiguration(info: valid.merging(change) { _, new in new }))
        }
        XCTAssertThrowsError(try UpdateConfiguration(info: ["SUFeedURL": "https://example.com/feed"]))
    }

    func testUpdateWaitsForPendingAuthenticationAndResumesAwakeAfterInstall() {
        let s = AppModelTests.Service(), a = AppModelTests.Auth()
        let m = AppModel(isolated: true, service: s, authentication: a)
        m.ready = true; m.flag = false; m.power = .init(isAC: true, batteryPercent: 100)
        a.result = nil; m.setAwake(true)
        XCTAssertFalse(m.beginUpdateInteraction())
        a.pending?(.success)
        XCTAssertTrue(m.beginUpdateInteraction())
        XCTAssertTrue(s.awake); XCTAssertEqual(s.restores, 0)
        // Installing quits the app: sleep is restored, and the next launch resumes the session.
        var quit = false
        m.onQuit = { quit = true }; m.quit()
        XCTAssertTrue(quit); XCTAssertFalse(s.awake)
        XCTAssertEqual(m.settings.resumeSession, ResumeSession(deadline: nil))
    }

    func testAcceptedUpdateBlocksNewSessionsAndFollowUntilCycleEnds() {
        let s = AppModelTests.Service(), a = AppModelTests.Auth()
        let m = AppModel(isolated: true, service: s, authentication: a)
        m.ready = true; m.flag = false; m.power = .init(isAC: true, batteryPercent: 100)
        XCTAssertTrue(m.beginUpdateInteraction())
        m.setAwake(true); m.startMinutes(15); m.changeMode(.followPowerSource)
        XCTAssertEqual(s.begins, 0); XCTAssertEqual(a.calls, 0)
        m.endUpdateInteraction(); m.setAwake(true)
        XCTAssertEqual(s.begins, 1)
    }

    func testUnknownSleepStateBlocksUpdate() {
        let m = AppModel(isolated: true)
        XCTAssertFalse(m.beginUpdateInteraction())
    }

    func testFailedTerminationReportsCancellationInsteadOfQuitting() {
        let s = AppModelTests.Service(), a = AppModelTests.Auth()
        let m = AppModel(isolated: true, service: s, authentication: a)
        m.ready = true; m.flag = false; m.power = .init(isAC: true, batteryPercent: 100)
        m.setAwake(true); s.failRestore = true
        var cancelled = false
        m.onQuit = { XCTFail("Failed restore must not authorize termination") }
        m.onQuitCancelled = { cancelled = true }
        m.quit()
        XCTAssertTrue(cancelled); XCTAssertTrue(s.awake)
    }
}

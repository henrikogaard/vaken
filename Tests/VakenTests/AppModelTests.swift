import XCTest
import VakenCore
import VakenService
@testable import vaken

final class AppModelTests: XCTestCase {
    final class Auth: UserAuthenticating {
        var result: GateOutcome? = .success
        var pending: ((GateOutcome) -> Void)?
        var calls = 0
        func authenticate(_ method: AuthenticationMethod, reply: @escaping (GateOutcome) -> Void) {
            calls += 1; if let result { reply(result) } else { pending = reply }
        }
        func cancel() {}
    }
    final class Service: SleepServicing {
        var awake = false, failRestore = false, holdBegin = false
        var config: SessionConfiguration?
        var begins = 0, restores = 0, updates = 0
        var protocolVersion = 2, policyWrites = 0
        var authRequired = true, failPolicyWrite = false
        var revision: Int64 = 0
        var lastBeginRevision: Int64?
        var pending: ((ServiceReply) -> Void)?
        var state: ServiceReply { .init(awake: awake, sessionID: awake ? "session" : nil, configuration: config,
                                       protocolVersion: protocolVersion, authenticationRequired: authRequired, policyRevision: revision) }
        func status(_ reply: @escaping (ServiceReply) -> Void) { reply(state) }
        func begin(_ configuration: SessionConfiguration, policyRevision: Int64?, reply: @escaping (ServiceReply) -> Void) {
            lastBeginRevision = policyRevision
            if let policyRevision, policyRevision != revision {
                var rejected = state; rejected.ok = false; rejected.message = "Policy changed"
                reply(rejected); return
            }
            begins += 1; config = configuration
            if holdBegin { pending = reply } else { awake = true; reply(state) }
        }
        func update(_ id: String, configuration: SessionConfiguration, reply: @escaping (ServiceReply) -> Void) {
            updates += 1; config = configuration; reply(state)
        }
        func heartbeat(_ id: String, reply: @escaping (ServiceReply) -> Void) { reply(state) }
        func restore(_ reply: @escaping (ServiceReply) -> Void) {
            restores += 1
            if failRestore { reply(.init(ok: false, awake: true, message: "restore failed")) }
            else { awake = false; config = nil; reply(state) }
        }
        func setAuthenticationRequired(_ required: Bool, policyRevision: Int64, reply: @escaping (ServiceReply) -> Void) {
            policyWrites += 1
            if failPolicyWrite || policyRevision != revision {
                var rejected = state; rejected.ok = false; rejected.message = "Policy write failed"
                reply(rejected); return
            }
            authRequired = required; revision += 1; reply(state)
        }
        func disconnect() {}
    }
    private func model(_ service: Service, _ auth: Auth) -> AppModel {
        let model = AppModel(isolated: true, service: service, authentication: auth)
        model.ready = true; model.flag = false; model.power = .init(isAC: true, batteryPercent: 100)
        model.helperProtocolVersion = service.protocolVersion
        return model
    }
    func testCancelDoesNotEnableOrArmTimer() {
        let s = Service(), a = Auth(); a.result = .cancelled
        let m = model(s, a); m.startMinutes(15)
        XCTAssertEqual(s.begins, 0); XCTAssertNil(m.deadline); XCTAssertTrue(m.paused)
    }
    func testOffDuringAuthenticationRejectsLateSuccess() {
        let s = Service(), a = Auth(); a.result = nil
        let m = model(s, a); m.setAwake(true); m.setAwake(false)
        a.pending?(.success)
        XCTAssertEqual(s.begins, 0); XCTAssertFalse(s.awake)
    }
    func testOffDuringHelperEnableCompensatesLateWrite() {
        let s = Service(), a = Auth(); s.holdBegin = true
        let m = model(s, a); m.setAwake(true); m.setAwake(false)
        s.awake = true; s.pending?(s.state)
        XCTAssertEqual(s.restores, 1); XCTAssertEqual(m.flag, false)
    }
    func testActiveTimerUpdatesAndExtendsWithoutReauth() {
        let s = Service(), a = Auth(), m: AppModel
        m = model(s, a); m.startMinutes(15)
        let first = m.deadline!
        m.extendSession()
        XCTAssertEqual(a.calls, 1); XCTAssertEqual(s.begins, 1); XCTAssertEqual(s.updates, 1)
        XCTAssertEqual(m.deadline!.timeIntervalSince(first), 900, accuracy: 1)
        m.startMinutes(30); XCTAssertEqual(a.calls, 1)
    }
    func testQuitFailureKeepsAppAlive() {
        let s = Service(), a = Auth(); s.failRestore = true
        let m = model(s, a); m.setAwake(true)
        m.onQuit = { XCTFail("Cannot quit after a failed restore") }
        m.quit(); XCTAssertNotNil(m.error); XCTAssertTrue(s.awake)
    }
    func testQuitVerifiesServiceRestore() {
        let s = Service(), a = Auth(); let m = model(s, a)
        m.setAwake(true); var quit = false
        m.onQuit = { quit = true }; m.quit()
        XCTAssertTrue(quit); XCTAssertFalse(s.awake)
    }
    func testSetupAndInvalidTimeDoNotAuthenticate() {
        let s = Service(), a = Auth(); let m = model(s, a)
        m.ready = false; m.setAwake(true)
        m.ready = true; m.startUntil(Date(timeIntervalSinceNow: -1)); m.startMinutes(-5)
        XCTAssertEqual(a.calls, 0); XCTAssertEqual(s.begins, 0)
    }
    func testHelperExpiryPausesFollowRatherThanReauthenticating() {
        let s = Service(), a = Auth(); let m = model(s, a)
        m.settings.mode = .followPowerSource; m.startMinutes(15)
        s.awake = false; s.config = nil
        m.checkSetup()
        XCTAssertTrue(m.paused); XCTAssertNil(m.deadline)
        XCTAssertEqual(a.calls, 1); XCTAssertEqual(s.begins, 1)
    }
    func testDisplayChoiceUpdatesExistingAuthorizedSession() {
        let s = Service(), a = Auth(); let m = model(s, a)
        m.setAwake(true); m.changeDisplay(true)
        XCTAssertEqual(s.config?.displayAwake, true)
        XCTAssertEqual(s.updates, 1); XCTAssertEqual(a.calls, 1)
        m.setAwake(false); XCTAssertNil(s.config)
    }
    func testEnableUsesLatestPowerPreferencesAfterAuthentication() {
        let s = Service(), a = Auth(); a.result = nil
        let m = model(s, a); m.setAwake(true)
        m.settings.mode = .followPowerSource
        m.settings.batteryFloor = 40
        m.settings.displayAwake = true
        a.pending?(.success)
        XCTAssertEqual(s.config?.mode, .followPowerSource)
        XCTAssertEqual(s.config?.batteryFloor, 40)
        XCTAssertEqual(s.config?.displayAwake, true)
    }
    func testOptOutAuthenticatesOnceThenNewStartsAreSilent() {
        let s = Service(), a = Auth(); let m = model(s, a)
        m.changeAuthenticationRequired(false)
        XCTAssertEqual(a.calls, 1); XCTAssertEqual(s.policyWrites, 1)
        XCTAssertFalse(m.authenticationRequired)
        m.startMinutes(15)
        XCTAssertEqual(a.calls, 1); XCTAssertEqual(s.begins, 1)
        XCTAssertEqual(s.lastBeginRevision, 1)
        m.setAwake(false); m.setAwake(true)
        XCTAssertEqual(a.calls, 1); XCTAssertEqual(s.begins, 2)
    }
    func testCancelledOptOutLeavesRequirementOn() {
        let s = Service(), a = Auth(); a.result = .cancelled
        let m = model(s, a); m.changeAuthenticationRequired(false)
        XCTAssertTrue(m.authenticationRequired); XCTAssertEqual(s.policyWrites, 0)
    }
    func testReenablingRequirementRestoresPromptOnNextStart() {
        let s = Service(), a = Auth(); s.authRequired = false; s.revision = 1
        let m = model(s, a); m.checkSetup()
        m.changeAuthenticationRequired(true)
        XCTAssertEqual(a.calls, 0); XCTAssertTrue(m.authenticationRequired)
        m.setAwake(true); XCTAssertEqual(a.calls, 1)
    }
    func testFailedPolicyWriteDoesNotOptimisticallyDisablePrompt() {
        let s = Service(), a = Auth(); s.failPolicyWrite = true
        let m = model(s, a); m.changeAuthenticationRequired(false)
        XCTAssertTrue(m.authenticationRequired); XCTAssertNotNil(m.error)
        m.setAwake(true); XCTAssertEqual(a.calls, 2)
    }
    func testLegacyHelperCannotOptOutAndAlwaysAuthenticates() {
        let s = Service(), a = Auth(); s.protocolVersion = 1; s.authRequired = false
        let m = model(s, a); m.changeAuthenticationRequired(false)
        XCTAssertEqual(s.policyWrites, 0)
        m.setAwake(true)
        XCTAssertEqual(a.calls, 1); XCTAssertNil(s.lastBeginRevision)
    }
    func testFreshHelperPolicyOverridesCachedOptOut() {
        let s = Service(), a = Auth(); let m = model(s, a)
        m.authenticationRequired = false
        m.setAwake(true)
        XCTAssertEqual(a.calls, 1); XCTAssertTrue(m.authenticationRequired)
    }
    func testOffWhileOptOutConfirmationIsOpenStillStopsSession() {
        let s = Service(), a = Auth(); let m = model(s, a)
        m.setAwake(true); a.result = nil
        m.changeAuthenticationRequired(false); m.setAwake(false)
        a.pending?(.success)
        XCTAssertFalse(s.awake); XCTAssertEqual(s.policyWrites, 0)
    }
    func testChangedPolicyRevisionRejectsAnInFlightEnable() {
        let s = Service(), a = Auth(); a.result = nil
        let m = model(s, a); m.setAwake(true)
        s.revision = 2 // Another instance changed the policy while this prompt was open.
        a.pending?(.success)
        XCTAssertEqual(s.lastBeginRevision, 0)
        XCTAssertEqual(s.begins, 0); XCTAssertFalse(s.awake); XCTAssertNotNil(m.error)
    }
}

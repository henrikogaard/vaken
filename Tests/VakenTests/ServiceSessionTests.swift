import XCTest
import Security
import VakenCore
import VakenService

final class ServiceSessionTests: XCTestCase {
    func testUnsetSystemFlagIsNormalButUnknownOutputIsNot() {
        XCTAssertEqual(parseSleepDisabled("System-wide power settings:\nCurrently in use:\n sleep 0\n"), false)
        XCTAssertNil(parseSleepDisabled("permission denied"))
        XCTAssertNil(parseSleepDisabled("System-wide power settings:\nCurrently in use:\n SleepDisabled invalid\n"))
    }
    func testLegacySettingsPreservePreferences() throws {
        let data = Data(#"{"mode":"manual","batteryFloor":30,"launchAtLogin":true,"notify":false}"#.utf8)
        let s = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(s.mode, .manual); XCTAssertEqual(s.batteryFloor, 30)
        XCTAssertTrue(s.launchAtLogin); XCTAssertFalse(s.notify)
        XCTAssertEqual(s.authentication, .touchID); XCTAssertFalse(s.displayAwake); XCTAssertNil(s.shortcut)
    }
    func testLeaseOwnerAndIDCannotBeSubstituted() {
        var lease = SessionLease(owner: "alice", uid: 501, configuration: .init(), uptime: 10)
        XCTAssertFalse(lease.renew(owner: "bob", id: lease.id, uptime: 20))
        XCTAssertFalse(lease.renew(owner: "alice", id: "other", uptime: 20))
        XCTAssertEqual(lease.heartbeat, 10)
        XCTAssertTrue(lease.renew(owner: "alice", id: lease.id, uptime: 20))
    }
    func testRecoveryDeadlinePowerAndProcessConditions() {
        let now = Date(), power = PowerState(isAC: true, batteryPercent: 100)
        let config = SessionConfiguration(deadline: now.addingTimeInterval(60), process: .init(pid: 22, seconds: 100, microseconds: 0, name: "build"))
        let lease = SessionLease(owner: "app", uid: 501, configuration: config, uptime: 10)
        XCTAssertNil(lease.endReason(now: now, uptime: 20, power: power, lpm: false, processRunning: true, consoleUID: 501))
        XCTAssertNotNil(lease.endReason(now: now, uptime: 40, power: power, lpm: false, processRunning: true, consoleUID: 501))
        XCTAssertNotNil(lease.endReason(now: now.addingTimeInterval(60), uptime: 20, power: power, lpm: false, processRunning: true, consoleUID: 501))
        XCTAssertNotNil(lease.endReason(now: now, uptime: 20, power: power, lpm: false, processRunning: false, consoleUID: 501))
        XCTAssertNotNil(lease.endReason(now: now, uptime: 20, power: .init(isAC: false, batteryPercent: 100), lpm: false, processRunning: true, consoleUID: 501))
        XCTAssertNotNil(lease.endReason(now: now, uptime: 20, power: power, lpm: false, processRunning: true, consoleUID: 502))
    }
    func testProcessExitAndPIDReuse() throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["15"]
        try p.run(); defer { if p.isRunning { p.terminate(); p.waitUntilExit() } }
        let identity = try XCTUnwrap(ProcessIdentity.capture(pid: p.processIdentifier, name: "test child"))
        XCTAssertTrue(identity.isRunning)
        let reused = ProcessIdentity(pid: identity.pid, seconds: identity.seconds + 1, microseconds: identity.microseconds, name: identity.name)
        XCTAssertFalse(reused.isRunning)
        p.terminate(); p.waitUntilExit(); XCTAssertFalse(identity.isRunning)
    }
    func testMalformedOrExpiredConfigurationRejected() throws {
        let now = Date()
        XCTAssertNil(SessionConfiguration.decode(Data(repeating: 65, count: 4097), now: now))
        XCTAssertNil(SessionConfiguration.decode(Data("{}".utf8), now: now))
        let invalid = SessionConfiguration(deadline: now.addingTimeInterval(-1))
        XCTAssertNil(SessionConfiguration.decode(try JSONEncoder().encode(invalid), now: now))
        XCTAssertNotNil(SessionConfiguration(batteryFloor: 0).validate(now: now))
    }
    func testSigningRequirementParsesAndRejectsUnrelatedSignedProgram() throws {
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(ServiceIdentity.requirement(identifier: "no.ogard.vaken") as CFString, [], &requirement), errSecSuccess)
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(URL(fileURLWithPath: "/usr/bin/true") as CFURL, [], &code), errSecSuccess)
        XCTAssertNotEqual(SecStaticCodeCheckValidity(try XCTUnwrap(code), [], try XCTUnwrap(requirement)), errSecSuccess)
    }
}

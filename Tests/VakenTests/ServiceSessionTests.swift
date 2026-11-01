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

    private func lease(mode: Mode, deadline: Date? = nil) -> SessionLease {
        SessionLease(owner: "a", uid: 501, configuration: SessionConfiguration(deadline: deadline, mode: mode), uptime: 0)
    }
    func testOneBadPowerReadingDoesNotEndSession() {
        var l = lease(mode: .manualPlusSafetyNet)
        let good = PowerState(isAC: true, batteryPercent: 100), bad = PowerState(isAC: nil, batteryPercent: nil)
        func check(_ power: PowerState) -> String? {
            l.check(now: Date(), uptime: 1, power: power, lpm: false, processRunning: true, consoleUID: 501)
        }
        XCTAssertNil(check(bad)); XCTAssertNil(check(bad)); XCTAssertEqual(l.unknownStateChecks, 2)
        XCTAssertNil(check(good)); XCTAssertEqual(l.unknownStateChecks, 0)
        XCTAssertNil(check(bad)); XCTAssertNil(check(bad))
        XCTAssertEqual(check(bad), "Power disconnected or unavailable")
    }
    func testOneBadConsoleReadingDoesNotEndSession() {
        var l = lease(mode: .manual)
        let power = PowerState(isAC: true, batteryPercent: 100)
        func check(_ uid: UInt32?) -> String? {
            l.check(now: Date(), uptime: 1, power: power, lpm: false, processRunning: true, consoleUID: uid)
        }
        XCTAssertNil(check(nil)); XCTAssertNil(check(nil)); XCTAssertNil(check(501))
        XCTAssertEqual(check(502), "User session changed")
        XCTAssertNil(check(nil)); XCTAssertNil(check(nil))
        XCTAssertEqual(check(nil), "User session changed")
    }
    func testDefiniteEndsAreNotDelayedByBadReadings() {
        let bad = PowerState(isAC: nil, batteryPercent: nil), now = Date()
        var unplugged = lease(mode: .manualPlusSafetyNet)
        XCTAssertEqual(unplugged.check(now: now, uptime: 1, power: .init(isAC: false, batteryPercent: 90), lpm: false, processRunning: true, consoleUID: 501),
                       "Power disconnected or unavailable")
        var silent = lease(mode: .manualPlusSafetyNet)
        XCTAssertEqual(silent.check(now: now, uptime: 40, power: bad, lpm: false, processRunning: true, consoleUID: nil), "Vaken stopped responding")
        var timed = lease(mode: .manualPlusSafetyNet, deadline: now.addingTimeInterval(-1))
        XCTAssertEqual(timed.check(now: now, uptime: 1, power: bad, lpm: false, processRunning: true, consoleUID: nil), "Timer ended")
    }
    func testManualModeIgnoresUnknownPower() {
        var l = lease(mode: .manual)
        for _ in 0..<5 {
            XCTAssertNil(l.check(now: Date(), uptime: 1, power: .init(isAC: nil, batteryPercent: nil), lpm: false, processRunning: true, consoleUID: 501))
        }
    }
    func testSessionLogAppendsAndRotates() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sessions.log")
        let log = SessionLog(url: url, maxBytes: 100)
        log.record("first"); log.record("second")
        var text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("first\n")); XCTAssertTrue(text.contains("second\n"))
        log.record(String(repeating: "x", count: 60))
        text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("xxx")); XCTAssertFalse(text.contains("first"))
        XCTAssertTrue(try String(contentsOf: url.appendingPathExtension("1"), encoding: .utf8).contains("first"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o644)
    }
    func testSessionLogDoesNotFollowSymlink() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("target"), url = folder.appendingPathComponent("sessions.log")
        try "keep".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        SessionLog(url: url).record("event")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
    }
}

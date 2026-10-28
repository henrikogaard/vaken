import XCTest
@testable import VakenCore

private final class ScriptedRunner: CommandRunning {
    var calls: [(path: String, args: [String])] = []
    var respond: (String, [String]) -> CommandResult = { _, _ in
        CommandResult(exitCode: -1, stdout: "", stderr: "no handler")
    }

    func run(_ path: String, _ arguments: [String]) -> CommandResult {
        calls.append((path, arguments))
        return respond(path, arguments)
    }
}

final class VakenCoreTests: XCTestCase {
    private let pmsetPath = "/usr/bin/pmset"
    private let osascriptPath = "/usr/bin/osascript"

    private static func output(_ flag: String) -> String {
        "System-wide power settings:\n Currently in use:\n SleepDisabled\t\t\(flag)\n"
    }

    // FR-1: parsing

    func testParseSleepDisabled() {
        XCTAssertEqual(parseSleepDisabled(" SleepDisabled\t\t0"), false)
        XCTAssertEqual(parseSleepDisabled(" SleepDisabled\t\t1"), true)
        XCTAssertNil(parseSleepDisabled(" SleepDisabled\t\tx"))
        XCTAssertNil(parseSleepDisabled(" SomethingElse\t1"))
        XCTAssertNil(parseSleepDisabled(""))
    }

    func testReadReflectsExternalChanges() {
        let runner = ScriptedRunner()
        let gate = SleepGate(runner: runner)
        var flag = true
        runner.respond = { path, _ in
            XCTAssertEqual(path, "/usr/bin/pmset")
            return CommandResult(exitCode: 0, stdout: Self.output(flag ? "1" : "0"), stderr: "")
        }
        XCTAssertEqual(gate.readSleepDisabled(), true)
        flag = false
        XCTAssertEqual(gate.readSleepDisabled(), false)  // no caching: every read hits the kernel
    }

    func testUnreadableWhenPmsetFails() {
        let runner = ScriptedRunner()
        let gate = SleepGate(runner: runner)
        runner.respond = { _, _ in CommandResult(exitCode: 1, stdout: "", stderr: "nope") }
        XCTAssertNil(gate.readSleepDisabled())
    }

    // FR-2: consented write, cancel, verify

    func testEnableRunsConsentedWriteThenVerifies() {
        let runner = ScriptedRunner()
        let gate = SleepGate(runner: runner)
        runner.respond = { path, args in
            if path == self.osascriptPath {
                XCTAssertTrue(args.joined(separator: " ").contains("disablesleep 1"), "enable must write 1")
                return CommandResult(exitCode: 0, stdout: "", stderr: "")
            }
            XCTAssertEqual(path, self.pmsetPath)
            return CommandResult(exitCode: 0, stdout: Self.output("1"), stderr: "")
        }
        XCTAssertEqual(gate.enable(), .success)
        XCTAssertEqual(runner.calls.count, 2)  // osascript write + pmset verify read
    }

    func testEnableCancelledLeavesStateUnchanged() {
        let runner = ScriptedRunner()
        let gate = SleepGate(runner: runner)
        runner.respond = { path, _ in
            if path == self.osascriptPath {
                return CommandResult(exitCode: 1, stdout: "", stderr: "execution error: User canceled. (-128)")
            }
            return CommandResult(exitCode: 0, stdout: Self.output("0"), stderr: "")
        }
        XCTAssertEqual(gate.enable(), .cancelled)
        XCTAssertEqual(
            runner.calls.filter { $0.path == self.pmsetPath }.count, 0,
            "cancel must not trigger a verify read or any state change")
    }

    func testFailureClassifiedNotCancelled() {
        let runner = ScriptedRunner()
        let gate = SleepGate(runner: runner)
        runner.respond = { path, _ in
            if path == self.osascriptPath {
                return CommandResult(exitCode: 1, stdout: "", stderr: "execution error: Authorization failed (-60008)")
            }
            return CommandResult(exitCode: 0, stdout: Self.output("0"), stderr: "")
        }
        guard case .failed(let message) = gate.enable() else {
            return XCTFail("expected .failed, not a cancel or success")
        }
        XCTAssertTrue(message.contains("Authorization failed"))
    }

    // FR-13: never a fake enabled

    func testEnableVerifyMismatchFails() {
        let runner = ScriptedRunner()
        let gate = SleepGate(runner: runner)
        runner.respond = { path, _ in
            if path == self.osascriptPath {
                return CommandResult(exitCode: 0, stdout: "", stderr: "")
            }
            return CommandResult(exitCode: 0, stdout: Self.output("0"), stderr: "")  // flag never changed
        }
        guard case .failed(let message) = gate.enable() else {
            return XCTFail("expected .failed on verify mismatch, got success — UI would show a fake enabled")
        }
        XCTAssertTrue(message.contains("verify failed"))
    }

    // FR-3: silent restore preferred when the grant is present

    func testRestorePrefersSilentGrant() {
        let runner = ScriptedRunner()
        let gate = SleepGate(runner: runner)
        runner.respond = { path, args in
            if path == "/usr/bin/sudo" {
                XCTAssertEqual(args, ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"], "NFR-3: exact args only")
                return CommandResult(exitCode: 0, stdout: "", stderr: "")
            }
            XCTAssertEqual(path, self.pmsetPath)
            return CommandResult(exitCode: 0, stdout: Self.output("0"), stderr: "")
        }
        XCTAssertEqual(gate.restoreInteractive(), .silent)
        XCTAssertFalse(runner.calls.contains { $0.path == self.osascriptPath }, "grant present: no dialog")
    }

    func testRestoreFallsBackToDialogWhenGrantMissing() {
        let runner = ScriptedRunner()
        let gate = SleepGate(runner: runner)
        runner.respond = { path, args in
            if path == "/usr/bin/sudo" {
                return CommandResult(exitCode: 1, stdout: "", stderr: "sudo: a password is required")
            }
            if path == self.osascriptPath {
                XCTAssertTrue(args.joined(separator: " ").contains("disablesleep 0"), "fallback must write 0")
                return CommandResult(exitCode: 0, stdout: "", stderr: "")
            }
            return CommandResult(exitCode: 0, stdout: Self.output("0"), stderr: "")
        }
        XCTAssertEqual(gate.restoreInteractive(), .dialog)
    }

    func testRestoreFallbackCancelled() {
        let runner = ScriptedRunner()
        let gate = SleepGate(runner: runner)
        runner.respond = { path, _ in
            if path == "/usr/bin/sudo" {
                return CommandResult(exitCode: 1, stdout: "", stderr: "sudo: a password is required")
            }
            if path == self.osascriptPath {
                return CommandResult(exitCode: 1, stdout: "", stderr: "execution error: User canceled. (-128)")
            }
            return CommandResult(exitCode: 0, stdout: Self.output("0"), stderr: "")
        }
        XCTAssertEqual(gate.restoreInteractive(), .cancelled)
    }

    // NFR-2: automation never prompts

    func testAutomaticRestoreNeverPrompts() {
        let runner = ScriptedRunner()
        let gate = SleepGate(runner: runner)
        runner.respond = { path, _ in
            if path == "/usr/bin/sudo" {
                return CommandResult(exitCode: 1, stdout: "", stderr: "sudo: a password is required")
            }
            return CommandResult(exitCode: 0, stdout: Self.output("1"), stderr: "")
        }
        guard case .failed = gate.restoreAutomatic() else {
            return XCTFail("expected .failed when the grant is missing, not a dialog")
        }
        XCTAssertFalse(runner.calls.contains { $0.path == self.osascriptPath }, "automated restore must never open a dialog")
    }

    func testAutomaticRestoreSilentSucceeds() {
        let runner = ScriptedRunner()
        let gate = SleepGate(runner: runner)
        runner.respond = { path, _ in
            if path == "/usr/bin/sudo" { return CommandResult(exitCode: 0, stdout: "", stderr: "") }
            return CommandResult(exitCode: 0, stdout: Self.output("0"), stderr: "")
        }
        XCTAssertEqual(gate.restoreAutomatic(), .silent)
    }

    // FR-13 on the silent path

    func testSilentRestoreVerifyMismatch() {
        let runner = ScriptedRunner()
        let gate = SleepGate(runner: runner)
        runner.respond = { path, _ in
            if path == "/usr/bin/sudo" { return CommandResult(exitCode: 0, stdout: "", stderr: "") }
            return CommandResult(exitCode: 0, stdout: Self.output("1"), stderr: "")  // flag did not change
        }
        guard case .failed(let message) = gate.restoreAutomatic() else {
            return XCTFail("expected .failed on silent verify mismatch — a fake silent success is worse than a dialog")
        }
        XCTAssertTrue(message.contains("verify failed"))
    }

    // Slice 3: power parsing

    func testParsePowerState() {
        let ac = "Now drawing from 'AC Power'\n -InternalBattery-0 (id = 1)\t100%; charged; 0:00 remaining present: true\n"
        let battery = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id = 1)\t97%; discharging; 4:11 remaining present: true\n"
        XCTAssertEqual(parsePowerState(ac), PowerState(isAC: true, batteryPercent: 100))
        XCTAssertEqual(parsePowerState(battery), PowerState(isAC: false, batteryPercent: 97))
        XCTAssertEqual(parsePowerState("junk output"), PowerState(isAC: nil, batteryPercent: nil))
    }

    func testParseLowPowerMode() {
        XCTAssertTrue(parseLowPowerMode(" powermode 1"))
        XCTAssertTrue(parseLowPowerMode(" lowpowermode 1"))
        XCTAssertFalse(parseLowPowerMode(" powermode 0"))
        XCTAssertFalse(parseLowPowerMode("nothing here"))
    }

    // Slice 3: FR-4/FR-5/FR-6 policy

    func testDecideFollowMode() {
        XCTAssertEqual(decide(PolicyInput(mode: .followPowerSource, flag: false, isAC: true)), .enableWithConsent)
        XCTAssertEqual(decide(PolicyInput(mode: .followPowerSource, flag: true, isAC: true)), .none)
        XCTAssertEqual(decide(PolicyInput(mode: .followPowerSource, flag: true, isAC: false)), .restoreSilently)
        XCTAssertEqual(decide(PolicyInput(mode: .followPowerSource, flag: false, isAC: false)), .none)
    }

    func testDecideManualModes() {
        XCTAssertEqual(decide(PolicyInput(mode: .manual, flag: true, isAC: false)), .none)
        XCTAssertEqual(decide(PolicyInput(mode: .manual, flag: false, isAC: true)), .none)
        XCTAssertEqual(decide(PolicyInput(mode: .manualPlusSafetyNet, flag: true, isAC: false)), .restoreSilently)
        XCTAssertEqual(decide(PolicyInput(mode: .manualPlusSafetyNet, flag: true, isAC: true)), .none)
        XCTAssertEqual(decide(PolicyInput(mode: .manualPlusSafetyNet, flag: false, isAC: true)), .none)
    }

    func testDecideFailsSafeOnUnreadable() {
        XCTAssertEqual(decide(PolicyInput(mode: .followPowerSource, flag: nil, isAC: nil)), .none)
        XCTAssertEqual(decide(PolicyInput(mode: .manualPlusSafetyNet, flag: true, isAC: nil)), .none)
        XCTAssertEqual(decide(PolicyInput(mode: .followPowerSource, flag: nil, isAC: true)), .none)
    }

    // Slice 3: FR-10 launch normalization

    func testLaunchAction() {
        XCTAssertEqual(launchAction(mode: .manual, flag: true, isAC: true), .restoreSilently)
        XCTAssertEqual(launchAction(mode: .manualPlusSafetyNet, flag: true, isAC: false), .restoreSilently)
        XCTAssertEqual(launchAction(mode: .followPowerSource, flag: true, isAC: true), .none)   // satisfied, no prompt
        XCTAssertEqual(launchAction(mode: .followPowerSource, flag: false, isAC: true), .enableWithConsent)
        XCTAssertEqual(launchAction(mode: .followPowerSource, flag: true, isAC: false), .restoreSilently)
        XCTAssertEqual(launchAction(mode: .manual, flag: nil, isAC: nil), .none)
    }

    // Slice 4: FR-7 sessions

    func testSessionExpiry() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Oslo")!
        let base = cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 13, minute: 37))!

        XCTAssertEqual(SessionLength.minutes30.expiry(from: base, calendar: cal), base.addingTimeInterval(30 * 60))
        XCTAssertEqual(SessionLength.hour2.expiry(from: base, calendar: cal), base.addingTimeInterval(2 * 60 * 60))
        XCTAssertNil(SessionLength.indefinite.expiry(from: base, calendar: cal))

        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: base))!
        XCTAssertEqual(SessionLength.untilMidnight.expiry(from: base, calendar: cal), midnight)

        // Exactly midnight → the *next* midnight, not zero-length.
        let atMidnight = cal.startOfDay(for: base)
        XCTAssertEqual(SessionLength.untilMidnight.expiry(from: atMidnight, calendar: cal),
                       cal.date(byAdding: .day, value: 1, to: atMidnight))
    }

    // Slice 4: FR-8 battery floor — every mode, battery only

    func testDecideBatteryFloor() {
        XCTAssertEqual(decide(PolicyInput(mode: .manual, flag: true, isAC: false, batteryPercent: 15, batteryFloor: 15)), .restoreSilently)
        XCTAssertEqual(decide(PolicyInput(mode: .manual, flag: true, isAC: false, batteryPercent: 8, batteryFloor: 15)), .restoreSilently)
        XCTAssertEqual(decide(PolicyInput(mode: .manualPlusSafetyNet, flag: true, isAC: false, batteryPercent: 3, batteryFloor: 15)), .restoreSilently)
        XCTAssertEqual(decide(PolicyInput(mode: .manual, flag: true, isAC: false, batteryPercent: 40, batteryFloor: 15)), .none)
        // On AC a low battery is charging — must not fire.
        XCTAssertEqual(decide(PolicyInput(mode: .manual, flag: true, isAC: true, batteryPercent: 8, batteryFloor: 15)), .none)
    }

    // Slice 4: FR-9 Low Power Mode

    func testDecideLowPowerMode() {
        XCTAssertEqual(decide(PolicyInput(mode: .manual, flag: true, isAC: false, lowPowerMode: true)), .restoreSilently)
        XCTAssertEqual(decide(PolicyInput(mode: .manualPlusSafetyNet, flag: true, isAC: false, lowPowerMode: true)), .restoreSilently)
        XCTAssertEqual(decide(PolicyInput(mode: .manual, flag: true, isAC: true, lowPowerMode: true)), .none)   // AC + LPM: ignored
    }

    // Slice 5: FR-14 settings

    func testSettingsRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaken-tests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var settings = AppSettings()
        settings.mode = .followPowerSource
        settings.batteryFloor = 30
        settings.launchAtLogin = true
        settings.notify = false
        XCTAssertTrue(SettingsStore.save(settings, to: url))
        XCTAssertEqual(SettingsStore.load(from: url), settings)
    }

    func testSettingsDefaultsWhenAbsentOrCorrupt() throws {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaken-tests-absent-\(UUID().uuidString).json")
        XCTAssertEqual(SettingsStore.load(from: absent), AppSettings())

        let corrupt = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaken-tests-corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: corrupt) }
        try "{ not json".write(to: corrupt, atomically: true, encoding: .utf8)
        XCTAssertEqual(SettingsStore.load(from: corrupt), AppSettings())
    }
}

import XCTest
@testable import VakenCore

final class PermissionSetupTests: XCTestCase {
    final class Runner: CommandRunning {
        var calls: [(String, [String])] = []
        var results: [CommandResult] = []
        func run(_ path: String, _ args: [String]) -> CommandResult {
            calls.append((path, args))
            return results.removeFirst()
        }
    }
    let rule = "    (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0\n"
    func testRejectsRootAndShellInputBeforeAuthorization() {
        for user in ["root", "", "henrik;id", "$(id)", "someone\nroot"] {
            let runner = Runner()
            let setup = PermissionSetup(runner: runner, user: user)
            guard case .failed = setup.install(script: "exit 0") else { return XCTFail() }
            XCTAssertFalse(setup.isReady())
            XCTAssertTrue(runner.calls.isEmpty)
        }
    }
    func testCachedOrBroadSudoPermissionIsNotReady() {
        for text in ["(ALL) ALL", "(root) /usr/bin/pmset -a disablesleep 0", "(root) NOPASSWD: ALL", "(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1"] {
            XCTAssertFalse(PermissionSetup.hasRestoreRule(text))
        }
        XCTAssertTrue(PermissionSetup.hasRestoreRule(rule))
    }
    func testInstallChecksPermissionWithoutChangingSleep() {
        let runner = Runner()
        runner.results = [.init(exitCode: 0, stdout: "", stderr: ""), .init(exitCode: 0, stdout: rule, stderr: "")]
        XCTAssertEqual(PermissionSetup(runner: runner, user: "henrik").install(script: "echo 'setup'"), .success)
        XCTAssertEqual(runner.calls.map { $0.0 }, ["/usr/bin/osascript", "/usr/bin/sudo"])
        XCTAssertTrue(runner.calls[0].1[1].contains("'henrik'"))
        XCTAssertEqual(runner.calls[1].1, ["-n", "-l"])
    }
    func testCancelDoesNotVerifyOrChangeState() {
        let runner = Runner()
        runner.results = [.init(exitCode: 1, stdout: "", stderr: "User canceled. (-128)")]
        XCTAssertEqual(PermissionSetup(runner: runner, user: "henrik").install(script: "exit 0"), .cancelled)
        XCTAssertEqual(runner.calls.count, 1)
    }
    func testInstallExitZeroIsNotEnough() {
        let runner = Runner()
        runner.results = [.init(exitCode: 0, stdout: "", stderr: ""), .init(exitCode: 1, stdout: "", stderr: "password required")]
        guard case .failed = PermissionSetup(runner: runner, user: "henrik").install(script: "exit 0") else { return XCTFail() }
    }
    func testShellQuoting() {
        XCTAssertEqual(PermissionSetup.shellQuote("a'b"), "'a'\\''b'")
        XCTAssertEqual(PermissionSetup.appleQuote("a\"b\nc\\d"), "\"a\\\"b\\nc\\\\d\"")
    }
}

import Foundation

public struct PermissionSetup {
    private let runner: CommandRunning
    private let user: String

    public init(runner: CommandRunning, user: String) {
        self.runner = runner
        self.user = user
    }

    public static func validUser(_ user: String) -> Bool {
        user != "root" && user.range(of: "^[a-zA-Z_][a-zA-Z0-9_.-]{0,63}$", options: .regularExpression) != nil
    }

    /// Check a passwordless rule, not whether sudo happens to have cached auth.
    /// This lists permissions; it never executes pmset or clears sudo's cache.
    public func isReady() -> Bool {
        guard Self.validUser(user) else { return false }
        let result = runner.run("/usr/bin/sudo", ["-n", "-l"])
        return result.exitCode == 0 && Self.hasRestoreRule(result.stdout)
    }

    public static func hasRestoreRule(_ output: String) -> Bool {
        output.components(separatedBy: .newlines).contains {
            $0.trimmingCharacters(in: .whitespaces) == "(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0"
        }
    }

    public func install(script: String) -> GateOutcome {
        guard Self.validUser(user), !script.isEmpty else {
            return .failed("Cannot configure automatic restore for this account.")
        }
        let shell = "/bin/sh -c \(Self.shellQuote(script)) vaken-setup \(Self.shellQuote(user))"
        let appleScript = "do shell script \(Self.appleQuote(shell)) with administrator privileges with prompt \(Self.appleQuote("Allow Vaken to restore normal sleep automatically."))"
        let result = runner.run("/usr/bin/osascript", ["-e", appleScript])
        guard result.exitCode == 0 else {
            if result.stderr.contains("(-128)") { return .cancelled }
            return .failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return isReady() ? .success : .failed("Setup finished, but automatic restore permission could not be verified. Try setup again.")
    }

    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func appleQuote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

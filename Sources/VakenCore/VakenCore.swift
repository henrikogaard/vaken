import Foundation

// MARK: - Command abstraction

public struct CommandResult: Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Something that can run one subprocess to completion. Blocking; no retry.
public protocol CommandRunning {
    func run(_ path: String, _ arguments: [String]) -> CommandResult
}

// MARK: - Gate outcome

public enum GateOutcome: Equatable {
    /// Write verified against a fresh kernel read.
    case success
    /// The user dismissed the authorization dialog; nothing changed.
    case cancelled
    /// Write or verification failed; the message is display-ready.
    case failed(String)
}

/// Result of a restore (disable → SleepDisabled 0). The silent/dialog split
/// is what FR-3 and NFR-2 hinge on.
public enum RestoreOutcome: Equatable {
    /// sudo -n path worked (grant present) — no human involved.
    case silent
    /// Grant missing: fell back to the admin dialog and succeeded.
    case dialog
    /// The user dismissed the fallback dialog.
    case cancelled
    /// Restore or verification failed; the message is display-ready.
    case failed(String)
}

// MARK: - pmset parsing

/// Parses `pmset -g` output for the SleepDisabled line.
/// true = never-sleep, false = normal, nil = absent/unreadable.
public func parseSleepDisabled(_ pmsetOutput: String) -> Bool? {
    for rawLine in pmsetOutput.split(separator: "\n") {
        let fields = rawLine.split { $0 == " " || $0 == "\t" }.map(String.init)
        guard fields.count >= 2, fields[0] == "SleepDisabled" else { continue }
        switch fields[1] {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }
    // macOS omits the system-wide flag until it has first been explicitly set.
    // Recognize that normal pmset output, but do not mask failed/malformed reads.
    if pmsetOutput.contains("System-wide power settings:"), pmsetOutput.contains("Currently in use:"),
       !pmsetOutput.contains("SleepDisabled") { return false }
    return nil
}

// MARK: - Sleep gate

/// The only privileged writer. Enable is consent-gated via the macOS admin
/// dialog; restore is silent-first, with a dialog fallback for interactive use
/// only (FR-2, FR-3, NFR-2). Set-then-verify on every write (FR-13, NFR-6).
public struct SleepGate {
    private let runner: CommandRunning

    public init(runner: CommandRunning) {
        self.runner = runner
    }

    /// Reads the kernel flag; nil when unreadable.
    public func readSleepDisabled() -> Bool? {
        let result = runner.run("/usr/bin/pmset", ["-g"])
        guard result.exitCode == 0 else { return nil }
        return parseSleepDisabled(result.stdout)
    }

    /// Enable never-sleep via the system admin dialog, then verify.
    /// Blocking: the dialog waits for a human.
    public func enable() -> GateOutcome {
        writeViaDialog(true)
    }

    /// User-initiated restore: silent sudo path first, admin-dialog fallback
    /// when the grant is missing (FR-3). Blocking.
    public func restoreInteractive() -> RestoreOutcome {
        let silent = silentRestore()
        if case .failed = silent {} else { return silent }
        switch writeViaDialog(false) {
        case .success: return .dialog
        case .cancelled: return .cancelled
        case .failed(let message): return .failed(message)
        }
    }

    /// Automation-initiated restore: silent path only. Never prompts (NFR-2);
    /// a failure is reported and the caller retries on the next poll.
    public func restoreAutomatic() -> RestoreOutcome {
        silentRestore()
    }

    private func silentRestore() -> RestoreOutcome {
        let result = runner.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"])
        guard result.exitCode == 0 else {
            return .failed(message(from: result.stderr))
        }
        // Set-then-verify on the silent path too (FR-13).
        guard let flag = readSleepDisabled(), flag == false else {
            return .failed("verify failed: SleepDisabled did not read back as 0")
        }
        return .silent
    }

    private func writeViaDialog(_ value: Bool) -> GateOutcome {
        let word = value ? "enable never-sleep" : "restore normal sleep"
        let script = """
        do shell script "/usr/bin/pmset -a disablesleep \(value ? 1 : 0)" with administrator privileges with prompt "Vaken: \(word)"
        """
        let result = runner.run("/usr/bin/osascript", ["-e", script])
        guard result.exitCode == 0 else {
            if isUserCancel(result.stderr) { return .cancelled }
            return .failed(message(from: result.stderr))
        }
        // Set-then-verify: a fresh kernel read is the only truth (NFR-6).
        guard let flag = readSleepDisabled(), flag == value else {
            return .failed("verify failed: SleepDisabled did not read back as \(value ? 1 : 0)")
        }
        return .success
    }

    private func isUserCancel(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("user canceled") || lower.contains("user cancelled") || lower.contains("-128)")
    }

    private func message(from stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "osascript failed with no message" : trimmed
    }

    /// One `pmset -g` read returning the flag plus the raw output (for LPM
    /// parsing) — one subprocess serves both (NFR-4 budget).
    public func readSystem() -> (flag: Bool?, output: String) {
        let result = runner.run("/usr/bin/pmset", ["-g"])
        guard result.exitCode == 0 else { return (nil, "") }
        return (parseSleepDisabled(result.stdout), result.stdout)
    }

    /// Power summary from `pmset -g ps`.
    public func readPower() -> PowerState {
        let result = runner.run("/usr/bin/pmset", ["-g", "ps"])
        guard result.exitCode == 0 else { return PowerState(isAC: nil, batteryPercent: nil) }
        return parsePowerState(result.stdout)
    }
}

// MARK: - Power state parsing

public struct PowerState: Equatable {
    public let isAC: Bool?
    public let batteryPercent: Int?

    public init(isAC: Bool?, batteryPercent: Int?) {
        self.isAC = isAC
        self.batteryPercent = batteryPercent
    }
}

/// Parses `pmset -g ps` output.
public func parsePowerState(_ psOutput: String) -> PowerState {
    var isAC: Bool?
    var batteryPercent: Int?
    for rawLine in psOutput.split(separator: "\n") {
        let line = String(rawLine)
        if line.contains("Now drawing from") {
            if line.contains("'AC Power'") {
                isAC = true
            } else if line.contains("'Battery Power'") {
                isAC = false
            }
        }
        if batteryPercent == nil, let range = line.range(of: #"\d+%;"#, options: .regularExpression) {
            batteryPercent = Int(line[range].dropLast(2))  // "97%;" → 97
        }
    }
    return PowerState(isAC: isAC, batteryPercent: batteryPercent)
}

/// Parses `pmset -g` output for Low Power Mode. The key appears as
/// `powermode` or `lowpowermode` depending on the macOS version.
public func parseLowPowerMode(_ pmsetOutput: String) -> Bool {
    for rawLine in pmsetOutput.split(separator: "\n") {
        let fields = rawLine.split { $0 == " " || $0 == "\t" }.map(String.init)
        guard fields.count >= 2 else { continue }
        if fields[0] == "lowpowermode" || fields[0] == "powermode" {
            return fields[1] == "1"
        }
    }
    return false
}

// MARK: - Modes and policy (FR-4…FR-6)

public enum Mode: String, Codable, CaseIterable {
    case manual
    case followPowerSource
    case manualPlusSafetyNet

    public var label: String {
        switch self {
        case .manual: return "Manual"
        case .followPowerSource: return "Follow power source"
        case .manualPlusSafetyNet: return "Manual + safety net"
        }
    }
}

public struct PolicyInput: Equatable {
    public var mode: Mode
    public var flag: Bool?
    public var isAC: Bool?
    public var batteryPercent: Int?
    public var lowPowerMode: Bool
    public var batteryFloor: Int

    public init(mode: Mode, flag: Bool?, isAC: Bool?,
                batteryPercent: Int? = nil, lowPowerMode: Bool = false, batteryFloor: Int = 15) {
        self.mode = mode
        self.flag = flag
        self.isAC = isAC
        self.batteryPercent = batteryPercent
        self.lowPowerMode = lowPowerMode
        self.batteryFloor = batteryFloor
    }
}

public enum PolicyAction: Equatable {
    case none
    case enableWithConsent
    case restoreSilently
}

/// Steady-state policy. Automation acts only on verified reads: an
/// unreadable flag or power state produces `.none` (fail-safe).
public func decide(_ input: PolicyInput) -> PolicyAction {
    guard let flag = input.flag, let isAC = input.isAC else { return .none }
    let onBattery = !isAC
    if onBattery && flag {
        if input.lowPowerMode { return .restoreSilently }                                    // FR-9
        if let pct = input.batteryPercent, pct <= input.batteryFloor { return .restoreSilently }  // FR-8
        switch input.mode {
        case .followPowerSource, .manualPlusSafetyNet: return .restoreSilently              // FR-5, FR-6
        case .manual: return .none                                                           // pure manual: warning only
        }
    }
    if isAC && !flag && input.mode == .followPowerSource { return .enableWithConsent }       // FR-5
    return .none
}

/// Launch normalization (FR-10): stale flags clear per mode; Follow + AC
/// resumes with a consent prompt only when the flag is off.
public func launchAction(mode: Mode, flag: Bool?, isAC: Bool?) -> PolicyAction {
    guard let flag = flag else { return .none }
    if flag {
        if mode == .followPowerSource && isAC == true { return .none }   // policy already satisfied
        return .restoreSilently                                         // manual modes and Follow + battery: start idle
    }
    if mode == .followPowerSource && isAC == true { return .enableWithConsent }   // resume follow
    return .none
}

// MARK: - Sessions (FR-7)

public enum SessionLength: String, CaseIterable {
    case minutes15 = "15 minutes"
    case minutes30 = "30 minutes"
    case hour1 = "1 hour"
    case hour2 = "2 hours"
    case hour4 = "4 hours"
    case untilMidnight = "until midnight"
    case indefinite = "indefinitely"

    /// Deadline for a session started at `from`; nil for indefinite.
    public func expiry(from date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .minutes15: return date.addingTimeInterval(15 * 60)
        case .minutes30: return date.addingTimeInterval(30 * 60)
        case .hour1: return date.addingTimeInterval(60 * 60)
        case .hour2: return date.addingTimeInterval(2 * 60 * 60)
        case .hour4: return date.addingTimeInterval(4 * 60 * 60)
        case .untilMidnight:
            let startOfDay = calendar.startOfDay(for: date)
            // startOfDay <= date always, so this is the next midnight (or +24 h at exact midnight).
            return calendar.date(byAdding: .day, value: 1, to: startOfDay)
        case .indefinite: return nil
        }
    }
}

// MARK: - Settings (FR-14)

public struct AppSettings: Codable, Equatable {
    public var mode: Mode = .manualPlusSafetyNet
    public var batteryFloor: Int = 15
    public var launchAtLogin: Bool = false
    public var notify: Bool = true
    public var authentication: AuthenticationMethod = .touchID
    public var displayAwake: Bool = false
    public var shortcut: KeyboardShortcut?

    public init() {}

    private enum CodingKeys: String, CodingKey { case mode, batteryFloor, launchAtLogin, notify, authentication, displayAwake, shortcut }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(Mode.self, forKey: .mode) ?? .manualPlusSafetyNet
        batteryFloor = try values.decodeIfPresent(Int.self, forKey: .batteryFloor) ?? 15
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        notify = try values.decodeIfPresent(Bool.self, forKey: .notify) ?? true
        authentication = try values.decodeIfPresent(AuthenticationMethod.self, forKey: .authentication) ?? .touchID
        displayAwake = try values.decodeIfPresent(Bool.self, forKey: .displayAwake) ?? false
        shortcut = try values.decodeIfPresent(KeyboardShortcut.self, forKey: .shortcut)
    }

    public init(mode: Mode, batteryFloor: Int, launchAtLogin: Bool, notify: Bool) {
        self.mode = mode
        self.batteryFloor = batteryFloor
        self.launchAtLogin = launchAtLogin
        self.notify = notify
    }
}

public enum SettingsStore {
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("no.ogard.vaken/settings.json")
    }

    /// Defaults when absent or corrupt (FR-14).
    public static func load(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url) else { return AppSettings() }
        guard let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        var validated = settings
        validated.batteryFloor = min(50, max(5, settings.batteryFloor))
        return validated
    }

    /// Atomic write; creates the directory. false on failure.
    @discardableResult
    public static func save(_ settings: AppSettings, to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

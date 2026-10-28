import Foundation
import Darwin

public struct ProcessIdentity: Codable, Equatable {
    public let pid: Int32
    public let seconds: UInt64
    public let microseconds: UInt64
    public let name: String

    public init(pid: Int32, seconds: UInt64, microseconds: UInt64, name: String) {
        self.pid = pid; self.seconds = seconds; self.microseconds = microseconds; self.name = name
    }
    public static func capture(pid: Int32, name: String) -> ProcessIdentity? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_status != UInt32(SZOMB) else { return nil }
        return .init(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec, name: String(name.prefix(200)))
    }
    public var isRunning: Bool {
        guard let current = Self.capture(pid: pid, name: name) else { return false }
        return current.seconds == seconds && current.microseconds == microseconds
    }
}

public struct SessionConfiguration: Codable, Equatable {
    public var deadline: Date?
    public var process: ProcessIdentity?
    public var mode: Mode
    public var batteryFloor: Int
    public var displayAwake: Bool
    public init(deadline: Date? = nil, process: ProcessIdentity? = nil, mode: Mode = .manualPlusSafetyNet,
                batteryFloor: Int = 15, displayAwake: Bool = false) {
        self.deadline = deadline; self.process = process; self.mode = mode
        self.batteryFloor = batteryFloor; self.displayAwake = displayAwake
    }
    public func validate(now: Date) -> String? {
        guard (5...50).contains(batteryFloor) else { return "Battery cutoff must be between 5% and 50%." }
        if let deadline, !deadline.timeIntervalSince1970.isFinite || deadline <= now { return "Choose an end time in the future." }
        if let process, process.pid <= 1 || process.seconds == 0 || process.name.count > 200 { return "Choose a valid running process." }
        return nil
    }
    public mutating func extend(now: Date, minutes: Int = 15) {
        deadline = max(deadline ?? now, now).addingTimeInterval(Double(minutes) * 60)
    }
    public static func decode(_ data: Data, now: Date) -> SessionConfiguration? {
        guard data.count <= 4096, let value = try? JSONDecoder().decode(Self.self, from: data), value.validate(now: now) == nil else { return nil }
        return value
    }
}

public struct SessionLease {
    public let id: String
    public let owner: String
    public let uid: UInt32
    public var configuration: SessionConfiguration
    public private(set) var heartbeat: TimeInterval
    public init(owner: String, uid: UInt32, configuration: SessionConfiguration, uptime: TimeInterval) {
        id = UUID().uuidString; self.owner = owner; self.uid = uid
        self.configuration = configuration; heartbeat = uptime
    }
    public mutating func renew(owner: String, id: String, uptime: TimeInterval) -> Bool {
        guard self.owner == owner && self.id == id else { return false }
        heartbeat = uptime; return true
    }
    public func endReason(now: Date, uptime: TimeInterval, power: PowerState, lpm: Bool,
                          processRunning: Bool, consoleUID: UInt32?) -> String? {
        if uptime - heartbeat >= 30 { return "Vaken stopped responding" }
        if consoleUID != uid { return "User session changed" }
        if let deadline = configuration.deadline, now >= deadline { return "Timer ended" }
        if configuration.process != nil && !processRunning { return "Tracked process exited" }
        // Unknown power state must not extend an AC-only lease.
        if configuration.mode != .manual && power.isAC != true { return "Power disconnected or unavailable" }
        if power.isAC == false {
            if lpm { return "Low Power Mode" }
            if let percent = power.batteryPercent, percent <= configuration.batteryFloor { return "Battery cutoff" }
        }
        return nil
    }
}

public enum AuthenticationMethod: String, Codable, CaseIterable {
    case touchID, password
    public var label: String { self == .touchID ? "Touch ID or password" : "Administrator password" }
}

public struct KeyboardShortcut: Codable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var label: String
    public init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }
}

import Foundation

/// User intent is separate from both the saved automation mode and kernel state.
public struct AwakeSession {
    public private(set) var paused = false
    public private(set) var restorePending = false
    public private(set) var deadline: Date?
    private var lastPower: Bool?
    private var retryAfter = Date.distantPast

    public init() {}

    public mutating func observePower(_ isAC: Bool?) {
        guard let isAC else { return }
        if let lastPower, lastPower != isAC { paused = false }
        lastPower = isAC
    }

    public mutating func requestOff() {
        paused = true
        restorePending = true
        deadline = nil
    }

    public mutating func requestOn() {
        paused = false
        restorePending = false
        deadline = nil
        retryAfter = .distantPast
    }

    public mutating func suppressConsent() { paused = true }

    public mutating func startTimer(_ length: SessionLength?, now: Date) {
        deadline = length?.expiry(from: now)
    }

    public mutating func tick(now: Date) {
        if let deadline, now >= deadline { requestOff() }
    }

    public mutating func restored() {
        restorePending = false
        deadline = nil
        retryAfter = .distantPast
    }

    public mutating func restoreFailed(now: Date) {
        restorePending = true
        retryAfter = now.addingTimeInterval(10)
    }

    public func action(_ input: PolicyInput, now: Date) -> PolicyAction {
        guard now >= retryAfter else { return .none }
        if restorePending { return .restoreSilently }
        let action = decide(input)
        return paused && action == .enableWithConsent ? .none : action
    }
}

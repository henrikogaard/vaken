import Foundation
import IOKit.pwr_mgt
import SystemConfiguration
import VakenCore
import VakenService

private func consoleUID() -> UInt32? {
    var uid: uid_t = 0, gid: gid_t = 0
    guard SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) != nil, uid > 0 else { return nil }
    return uid
}

private final class Runner: CommandRunning {
    func run(_ path: String, _ arguments: [String]) -> CommandResult {
        let p = Process(), output = Pipe()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = arguments
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        p.standardOutput = output; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return .init(exitCode: -1, stdout: "", stderr: "Could not run power utility.") }
        let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
        let hardTimeout = DispatchWorkItem { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: timeout)
        DispatchQueue.global().asyncAfter(deadline: .now() + 6, execute: hardTimeout)
        defer { timeout.cancel(); hardTimeout.cancel() }
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return .init(exitCode: p.terminationStatus, stdout: String(decoding: bytes, as: UTF8.self), stderr: "")
    }
}

private final class Helper: NSObject, NSXPCListenerDelegate {
    let queue = DispatchQueue(label: "no.ogard.vaken.helper.state")
    private let runner = Runner()
    private var lease: SessionLease?
    private var displayAssertion: IOPMAssertionID = 0
    private var ownsFlag = false
    private var restoring = false
    private var lastMessage: String?
    private var timer: DispatchSourceTimer?
    private let marker = URL(fileURLWithPath: "/var/db/no.ogard.vaken/owned")
    private let policies = AuthenticationPolicyStore(url: URL(fileURLWithPath: "/var/db/no.ogard.vaken/authentication.json"))

    func start() {
        queue.async {
            self.ownsFlag = FileManager.default.fileExists(atPath: self.marker.path)
            if self.ownsFlag { _ = self.restoreOwned(reason: "Recovered interrupted session") }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume(); self.timer = timer
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier > 0, connection.effectiveUserIdentifier == consoleUID() else { return false }
        connection.setCodeSigningRequirement(ServiceIdentity.requirement(identifier: "no.ogard.vaken"))
        let peer = Peer(helper: self, uid: connection.effectiveUserIdentifier)
        connection.exportedInterface = NSXPCInterface(with: SleepControlProtocol.self)
        connection.exportedObject = peer
        connection.invalidationHandler = { [weak self] in
            self?.queue.async { [weak self] in
                guard let self, self.lease?.owner == peer.owner else { return }
                _ = self.restoreOwned(reason: "Vaken disconnected")
            }
        }
        connection.resume()
        return true
    }

    private func awake() -> Bool? { SleepGate(runner: runner).readSleepDisabled() }
    func response(uid: UInt32, ok: Bool = true, message: String? = nil) -> Data {
        let policy = policies.policy(for: uid)
        return ServiceReply(ok: ok, awake: awake(), sessionID: lease?.id,
                     configuration: lease?.configuration, message: message ?? lastMessage,
                     authenticationRequired: policy.required, policyRevision: policy.revision).data
    }
    func perform(_ operation: String, peer: Peer, id: String? = nil, data: Data? = nil,
                 policyRevision: Int64? = nil, required: Bool? = nil, reply: @escaping (Data) -> Void) {
        queue.async {
            func state(ok: Bool = true, message: String? = nil) -> Data { self.response(uid: peer.uid, ok: ok, message: message) }
            guard consoleUID() == peer.uid else { reply(ServiceReply(ok: false, message: "This is not the active user session.").data); return }
            if let lease = self.lease, lease.owner != peer.owner {
                reply(ServiceReply(ok: false, awake: self.awake(), message: "Another Vaken connection owns the session.").data); return
            }
            switch operation {
            case "status": break
            case "authenticationPolicy":
                guard let required, let policyRevision else { reply(state(ok: false, message: "Invalid authentication setting.")); return }
                do { try self.policies.set(required: required, for: peer.uid, expectedRevision: policyRevision) }
                catch AuthenticationPolicyStore.Failure.staleRevision {
                    reply(state(ok: false, message: "Authentication settings changed. Please try again.")); return
                } catch { reply(state(ok: false, message: "Could not save the authentication setting.")); return }
                self.lastMessage = nil
            case "restore":
                guard self.restoreOwned(reason: "Normal sleep restored", explicit: true) else {
                    reply(state(ok: false)); return
                }
            case "heartbeat":
                guard self.lease != nil else { reply(state()); return }
                guard var lease = self.lease, lease.renew(owner: peer.owner, id: id ?? "", uptime: ProcessInfo.processInfo.systemUptime) else {
                    reply(state(ok: false, message: "Session ended.")); return
                }
                self.lease = lease
            case "begin", "beginWithPolicy", "update":
                if operation == "beginWithPolicy", policyRevision != self.policies.policy(for: peer.uid).revision {
                    reply(state(ok: false, message: "Authentication settings changed. Please try again.")); return
                }
                guard !self.restoring else { reply(state(ok: false, message: "A restore is still pending.")); return }
                guard let data, let config = SessionConfiguration.decode(data, now: Date()) else {
                    reply(state(ok: false, message: "Invalid or expired session settings.")); return
                }
                if operation == "update", self.lease?.id != id {
                    reply(state(ok: false, message: "Session ended.")); return
                }
                let candidate = SessionLease(owner: peer.owner, uid: peer.uid, configuration: config, uptime: ProcessInfo.processInfo.systemUptime)
                let system = SleepGate(runner: self.runner).readSystem()
                if let reason = candidate.endReason(now: Date(), uptime: ProcessInfo.processInfo.systemUptime,
                    power: SleepGate(runner: self.runner).readPower(), lpm: parseLowPowerMode(system.output),
                    processRunning: config.process?.isRunning ?? true, consoleUID: consoleUID()) {
                    if operation == "update" {
                        let restored = self.restoreOwned(reason: reason)
                        reply(state(ok: restored, message: reason)); return
                    }
                    reply(state(ok: false, message: reason)); return
                }
                let previousConfig = self.lease?.configuration
                if operation != "update" {
                    do {
                        try FileManager.default.createDirectory(at: self.marker.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                                attributes: [.posixPermissions: 0o700])
                        try Data("owned\n".utf8).write(to: self.marker, options: .atomic)
                    } catch { reply(state(ok: false, message: "Could not persist recovery state.")); return }
                    self.ownsFlag = true
                    let result = self.runner.run("/usr/bin/pmset", ["-a", "disablesleep", "1"])
                    guard result.exitCode == 0, self.awake() == true else {
                        _ = self.restoreOwned(reason: "Enable could not be verified")
                        reply(state(ok: false, message: "Enable could not be verified.")); return
                    }
                    self.lease = candidate
                } else { self.lease?.configuration = config }
                self.lastMessage = nil
                guard self.setDisplay(config.displayAwake) else {
                    if operation != "update" { _ = self.restoreOwned(reason: "Display assertion failed") }
                    else if let previousConfig { self.lease?.configuration = previousConfig }
                    reply(state(ok: false, message: "Could not apply the display-awake setting.")); return
                }
            default: reply(state(ok: false, message: "Unsupported operation.")); return
            }
            reply(state())
        }
    }

    private func restoreOwned(reason: String, explicit: Bool = false) -> Bool {
        let displayReleased = setDisplay(false)
        guard ownsFlag || explicit else { return true }
        restoring = true
        let result = runner.run("/usr/bin/pmset", ["-a", "disablesleep", "0"])
        guard result.exitCode == 0, awake() == false, displayReleased else {
            lastMessage = "Normal sleep could not be restored; retrying."
            return false
        }
        lease = nil; ownsFlag = false; restoring = false; lastMessage = reason
        // Only our fixed, root-owned recovery marker is removed.
        if FileManager.default.fileExists(atPath: marker.path) { try? FileManager.default.removeItem(at: marker) }
        return true
    }

    private func tick() {
        if restoring { _ = restoreOwned(reason: "Normal sleep restored", explicit: true); return }
        guard let lease else {
            if ownsFlag { _ = restoreOwned(reason: "Recovered interrupted session") }
            return
        }
        let gate = SleepGate(runner: runner), system = gate.readSystem()
        if system.flag == false { _ = restoreOwned(reason: "Sleep restored outside Vaken"); return }
        if let reason = lease.endReason(now: Date(), uptime: ProcessInfo.processInfo.systemUptime,
            power: gate.readPower(), lpm: parseLowPowerMode(system.output),
            processRunning: lease.configuration.process?.isRunning ?? true, consoleUID: consoleUID()) {
            _ = restoreOwned(reason: reason)
        }
    }

    @discardableResult private func setDisplay(_ enabled: Bool) -> Bool {
        if !enabled, displayAssertion != 0 {
            guard IOPMAssertionRelease(displayAssertion) == kIOReturnSuccess else { return false }
            displayAssertion = 0
        }
        if enabled, displayAssertion == 0 {
            return IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "Vaken display session" as CFString, &displayAssertion) == kIOReturnSuccess
        }
        return true
    }
}

private final class Peer: NSObject, SleepControlProtocol {
    let owner = UUID().uuidString
    let uid: UInt32
    let helper: Helper
    init(helper: Helper, uid: UInt32) { self.helper = helper; self.uid = uid }
    func status(reply: @escaping (Data) -> Void) { helper.perform("status", peer: self, reply: reply) }
    func begin(configuration: Data, reply: @escaping (Data) -> Void) { helper.perform("begin", peer: self, data: configuration, reply: reply) }
    func update(sessionID: String, configuration: Data, reply: @escaping (Data) -> Void) { helper.perform("update", peer: self, id: sessionID, data: configuration, reply: reply) }
    func heartbeat(sessionID: String, reply: @escaping (Data) -> Void) { helper.perform("heartbeat", peer: self, id: sessionID, reply: reply) }
    func restore(reply: @escaping (Data) -> Void) { helper.perform("restore", peer: self, reply: reply) }
    func beginWithPolicy(configuration: Data, policyRevision: Int64, reply: @escaping (Data) -> Void) {
        helper.perform("beginWithPolicy", peer: self, data: configuration, policyRevision: policyRevision, reply: reply)
    }
    func setAuthenticationRequired(_ required: Bool, policyRevision: Int64, reply: @escaping (Data) -> Void) {
        helper.perform("authenticationPolicy", peer: self, policyRevision: policyRevision, required: required, reply: reply)
    }
}

guard geteuid() == 0 else { fputs("Vaken helper must be launched by its registered system service.\n", stderr); exit(1) }
private let helper = Helper()
let listener = NSXPCListener(machServiceName: ServiceIdentity.name)
listener.delegate = helper
helper.start(); listener.resume()
RunLoop.current.run()

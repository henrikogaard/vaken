import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications
import VakenCore
import VakenService

final class AppModel: ObservableObject {
    @Published var flag: Bool?
    @Published var power = PowerState(isAC: nil, batteryPercent: nil)
    @Published var settings = AppSettings()
    @Published var ready = false
    @Published var checkingSetup = false
    @Published var busy: String?
    @Published var error: String?
    @Published var paused = false
    @Published var deadline: Date?
    @Published var trackedProcess: ProcessIdentity?
    @Published var loginStatus = ""
    @Published var setupStatus = ""
    @Published var recordingShortcut = false
    @Published var clock = Date()
    @Published var helperProtocolVersion = 1
    @Published var authenticationRequired = true
    @Published private(set) var updateInProgress = false
    private let service: SleepServicing
    private let authentication: UserAuthenticating
    private let preview: Bool
    private let isolated: Bool
    private var sessionID: String?
    private var configuration: SessionConfiguration?
    private var lastPower: Bool?
    private var poll: Timer?
    private var clockTimer: Timer?
    private var polling = false
    private var generation = 0
    private var quitRequested = false
    private var stopRequested = false
    private var resumeChecked = false
    private var retryAfter = Date.distantPast
    private var shortcut: GlobalShortcut?
    var onChange: (() -> Void)?
    var onQuit: (() -> Void)?
    var onQuitCancelled: (() -> Void)?
    var supportsAuthenticationPolicy: Bool { ready && helperProtocolVersion >= 2 }
    var helperNeedsUpdate: Bool { ready && helperProtocolVersion < ServiceIdentity.protocolVersion }

    init(preview: Bool = false, isolated: Bool = false,
         service: SleepServicing = HelperClient(), authentication: UserAuthenticating = NativeAuthentication()) {
        self.preview = preview; self.isolated = isolated
        self.service = service; self.authentication = authentication
        if !preview && !isolated { settings = SettingsStore.load(from: SettingsStore.defaultURL()) }
    }
    var status: String {
        if let busy { return busy }
        guard let flag else { return ready ? "Reading sleep state…" : "Helper setup required" }
        return flag ? "On · Your Mac stays awake" : "Off · Normal sleep allowed"
    }
    var powerText: String {
        guard let ac = power.isAC else { return "Power source unavailable" }
        return (ac ? "Plugged in" : "On battery") + (power.batteryPercent.map { " · \($0)%" } ?? "")
    }
    var remaining: String? {
        guard let deadline else { return nil }
        let seconds = max(0, Int(ceil(deadline.timeIntervalSince(clock))))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var sessionText: String? {
        let end = deadline.map { "ends at \($0.formatted(date: .omitted, time: .shortened))" }
        if let trackedProcess { return "Until \(trackedProcess.name) exits" + (end.map { " or \($0)" } ?? "") }
        return end.map { "E" + $0.dropFirst() }
    }
    var policyText: String {
        if paused && settings.mode == .followPowerSource { return "Automatic mode paused until power changes." }
        switch settings.mode {
        case .manual: return "You decide when your Mac stays awake."
        case .followPowerSource: return "Automatically follows your power connection."
        case .manualPlusSafetyNet: return "Restores normal sleep when unplugged."
        }
    }
    func start() {
        guard !preview else { return }
        refreshLoginStatus()
        if !isolated {
            shortcut = GlobalShortcut()
            shortcut?.action = { [weak self] in guard let self else { return }; self.setAwake(self.flag != true) }
            if let message = shortcut?.register(settings.shortcut) { error = message }
        }
        checkSetup(); refreshPower()
        poll = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refreshPower(); self?.refreshService() }
        RunLoop.main.add(poll!, forMode: .common)
        clockTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.clock = Date() }
        RunLoop.main.add(clockTimer!, forMode: .common)
    }
    func checkSetup() {
        guard !preview else { return }
        if !isolated {
            let status = SMAppService.daemon(plistName: ServiceIdentity.plist).status
            setupStatus = status == .requiresApproval ? "Approve Vaken in System Settings → Login Items & Extensions." : ""
            if status != .enabled { ready = false; changed(); return }
        }
        refreshService()
    }
    func configureRestore() {
        guard !preview, !isolated, busy == nil else { return }
        if helperNeedsUpdate { updateHelper(); return }
        do {
            let service = SMAppService.daemon(plistName: ServiceIdentity.plist)
            if service.status != .enabled { try service.register() }
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            error = nil; checkSetup()
        } catch { self.error = "Helper setup failed: \(error.localizedDescription)" }
    }
    private func updateHelper() {
        guard flag == false, sessionID == nil else {
            error = "End the current Keep awake session before updating the helper."; return
        }
        busy = "Updating helper…"; error = nil; generation += 1; changed()
        service.restore { [weak self] response in
            guard let self else { return }
            guard response.ok, response.awake == false else {
                self.busy = nil; self.error = "Could not verify normal sleep before updating the helper."; self.changed(); return
            }
            self.accept(response)
            self.service.disconnect()
            let helper = SMAppService.daemon(plistName: ServiceIdentity.plist)
            helper.unregister { error in
                DispatchQueue.main.async {
                    self.ready = false; self.authenticationRequired = true; self.helperProtocolVersion = 1
                    do {
                        if let error { throw error }
                        try helper.register()
                        if helper.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                    } catch { self.error = "Helper update failed: \(error.localizedDescription)" }
                    self.busy = nil; self.changed(); self.checkSetup()
                    self.finishPendingStop()
                }
            }
        }
    }
    private func refreshService() {
        guard !preview, !polling else { return }
        polling = true
        let observationGeneration = generation
        let callback: (ServiceReply) -> Void = { [weak self] response in
            guard let self else { return }
            self.polling = false
            guard self.generation == observationGeneration, self.busy == nil else { return }
            let hadSession = self.sessionID != nil
            self.accept(response)
            if hadSession && response.ok && response.sessionID == nil {
                self.paused = true
                if !self.quitRequested { self.forgetSession() }
            }
            self.changed()
            if self.quitRequested, self.busy == nil, Date() >= self.retryAfter { self.stop(interactive: false) }
            else { self.resumeIfNeeded(); self.evaluateFollow() }
        }
        if let id = sessionID { service.heartbeat(id, reply: callback) }
        else { service.status(callback) }
    }
    private func accept(_ response: ServiceReply) {
        helperProtocolVersion = response.protocolVersion
        authenticationRequired = response.protocolVersion < 2 || response.authenticationRequired
        if response.ok {
            ready = true; flag = response.awake
            sessionID = response.sessionID; configuration = response.configuration
            deadline = response.configuration?.deadline; trackedProcess = response.configuration?.process
            if sessionID != nil { rememberSession(configuration) }
        } else {
            error = response.message ?? "The helper could not complete the request."
            if response.sessionID == nil && response.awake == false {
                flag = false; sessionID = nil; configuration = nil; deadline = nil; trackedProcess = nil; paused = true
            }
            // A failed heartbeat does not mean a new session may be started.
            if response.awake == nil { ready = false }
        }
    }
    private func refreshPower() {
        guard !preview else { return }
        DispatchQueue.global(qos: .utility).async {
            let reader = SleepGate(runner: ProcessRunner())
            let power = reader.readPower()
            let observed = reader.readSleepDisabled()
            DispatchQueue.main.async {
                if !self.ready, self.busy == nil { self.flag = observed }
                if let ac = power.isAC {
                    if let prior = self.lastPower, prior != ac { self.paused = false }
                    self.lastPower = ac
                }
                self.power = power
                if power.isAC != true && self.settings.mode != .manual && self.busy != nil {
                    self.generation += 1; self.authentication.cancel(); self.paused = true
                }
                self.changed()
            }
        }
    }
    private func evaluateFollow() {
        guard busy == nil, !updateInProgress, ready, flag == false, !paused, settings.mode == .followPowerSource,
              power.isAC == true, Date() >= retryAfter else { return }
        setAwake(true)
    }
    /// Starts the session that was on when Vaken last quit or the Mac restarted, once per launch.
    func resumeIfNeeded() {
        guard !resumeChecked, busy == nil, !updateInProgress, ready, power.isAC != nil else { return }
        resumeChecked = true
        guard flag == false, let resume = settings.resumeSession, settings.mode != .followPowerSource else { return }
        if let deadline = resume.deadline, deadline <= Date() { forgetSession(); return }
        guard settings.mode == .manual || power.isAC == true else { forgetSession(); return }
        startSession(makeConfiguration(deadline: resume.deadline))
    }
    private func rememberSession(_ config: SessionConfiguration?) {
        // A process-linked session cannot outlive its process, so it is not resumed.
        let next = config.flatMap { $0.process == nil ? ResumeSession(deadline: $0.deadline) : nil }
        guard settings.resumeSession != next else { return }
        settings.resumeSession = next; persist()
    }
    private func forgetSession() {
        guard settings.resumeSession != nil else { return }
        settings.resumeSession = nil; persist()
    }
    private func makeConfiguration(deadline: Date? = nil, process: ProcessIdentity? = nil) -> SessionConfiguration {
        .init(deadline: deadline, process: process, mode: settings.mode, batteryFloor: settings.batteryFloor, displayAwake: settings.displayAwake)
    }
    func setAwake(_ awake: Bool, duration: SessionLength? = nil) {
        if awake {
            let seconds: TimeInterval? = duration == .untilMidnight || duration == .indefinite ? nil : duration?.expiry(from: Date())?.timeIntervalSinceNow
            startSession(makeConfiguration(deadline: duration?.expiry(from: Date())), relativeDuration: seconds)
        }
        else { stop(interactive: true) }
    }
    func startMinutes(_ minutes: Int) {
        guard minutes > 0, minutes <= 525600 else { error = "Enter between 1 and 525600 minutes."; return }
        startSession(makeConfiguration(deadline: Date().addingTimeInterval(Double(minutes) * 60)), relativeDuration: Double(minutes) * 60)
    }
    func startUntil(_ date: Date) { startSession(makeConfiguration(deadline: date)) }
    func startProcess(pid: Int32, name: String) {
        guard let process = ProcessIdentity.capture(pid: pid, name: name) else { error = "That process is not running or cannot be inspected."; return }
        startSession(makeConfiguration(process: process))
    }
    func extendSession() {
        guard var config = configuration else { startMinutes(15); return }
        config.extend(now: Date()); startSession(config)
    }
    func removeDeadline() {
        guard var config = configuration, config.deadline != nil else { return }
        config.deadline = nil; startSession(config)
    }
    private func startSession(_ config: SessionConfiguration, relativeDuration: TimeInterval? = nil) {
        guard !preview, busy == nil else { return }
        guard !updateInProgress else { error = "Finish or dismiss the update before starting Keep awake."; return }
        guard ready else { error = "Enable the Vaken helper in Settings first."; return }
        guard let flag else { error = "Wait for system sleep state."; return }
        if let reason = config.validate(now: Date()) { error = reason; return }
        guard config.mode == .manual || power.isAC == true else { error = "This mode requires AC power."; return }
        error = nil; paused = false; generation += 1
        let intent = generation
        if flag, let id = sessionID {
            busy = "Updating session…"; changed()
            service.update(id, configuration: config) { [weak self] response in
                guard let self else { return }
                self.busy = nil; self.accept(response); self.changed()
                if self.generation != intent { self.stop(interactive: false) }
            }
            return
        }
        busy = "Checking authentication settings…"
        changed()
        // Always read the helper-owned policy afresh before a new session.
        service.status { [weak self] response in
            guard let self else { return }
            guard self.generation == intent else {
                self.busy = nil; self.changed(); self.finishPendingStop()
                return
            }
            self.accept(response)
            guard response.ok else { self.busy = nil; self.paused = true; self.changed(); return }
            let revision = response.protocolVersion >= 2 ? response.policyRevision : nil
            let authorize: (@escaping (GateOutcome) -> Void) -> Void = { completion in
                if self.authenticationRequired {
                    self.busy = self.settings.authentication == .touchID ? "Waiting for Touch ID or password…" : "Waiting for administrator authorization…"
                    self.changed()
                    self.authentication.authenticate(self.settings.authentication, reply: completion)
                } else { completion(.success) }
            }
            authorize { [weak self] outcome in
                guard let self else { return }
                guard self.generation == intent else {
                    self.busy = nil; self.changed(); self.finishPendingStop(); return
                }
                switch outcome {
                case .cancelled: self.busy = nil; self.paused = true; self.forgetSession(); self.changed()
                case .failed(let message): self.busy = nil; self.error = message; self.paused = true; self.forgetSession(); self.changed()
                case .success:
                    self.busy = "Enabling Keep awake…"; self.changed()
                    var authorizedConfig = config
                    authorizedConfig.mode = self.settings.mode
                    authorizedConfig.batteryFloor = self.settings.batteryFloor
                    authorizedConfig.displayAwake = self.settings.displayAwake
                    if let relativeDuration { authorizedConfig.deadline = Date().addingTimeInterval(relativeDuration) }
                    self.service.begin(authorizedConfig, policyRevision: revision) { [weak self] response in
                        guard let self else { return }
                        self.busy = nil; self.accept(response)
                        if !response.ok { self.paused = true }
                        self.changed()
                        if self.generation != intent { self.stop(interactive: false) }
                        else if response.ok { self.notify("Keep awake is on") }
                    }
                }
            }
        }
    }
    private func stop(interactive: Bool) {
        guard !preview else { return }
        generation += 1; paused = true; stopRequested = true; authentication.cancel()
        if !quitRequested { forgetSession() }
        if busy != nil { changed(); return }
        stopRequested = false
        busy = "Restoring normal sleep…"; changed()
        service.restore { [weak self] response in
            guard let self else { return }
            self.busy = nil; self.accept(response)
            if response.ok && response.awake == false {
                self.error = nil; self.retryAfter = .distantPast
                self.notify("Normal sleep restored")
                if self.quitRequested { self.onQuit?(); return }
            } else {
                self.error = response.message ?? "Could not verify normal sleep. Vaken remains open."
                self.retryAfter = Date().addingTimeInterval(10)
                if self.quitRequested {
                    self.quitRequested = false
                    self.onQuitCancelled?()
                }
                // Helper lease/disconnection handling remains the backstop.
            }
            self.changed()
        }
    }
    func quit() {
        guard !preview else { return }
        if !ready && sessionID == nil && flag == false && busy == nil {
            if isolated || SleepGate(runner: ProcessRunner()).readSleepDisabled() == false { onQuit?(); return }
        }
        quitRequested = true; stop(interactive: true)
    }
    func beginUpdateInteraction() -> Bool {
        guard flag == false, busy == nil, sessionID == nil, !quitRequested else { return false }
        updateInProgress = true; paused = true; changed()
        return true
    }
    func endUpdateInteraction() { updateInProgress = false; changed() }
    func changeMode(_ mode: Mode) { settings.mode = mode; persist(); updatePolicy() }
    func changeFloor(_ floor: Int) { settings.batteryFloor = min(50, max(5, floor)); persist(); updatePolicy() }
    func changeDisplay(_ value: Bool) { settings.displayAwake = value; persist(); updatePolicy() }
    func changeAuthentication(_ value: AuthenticationMethod) { settings.authentication = value; persist() }
    func changeAuthenticationRequired(_ required: Bool) {
        guard !preview, busy == nil else { return }
        guard supportsAuthenticationPolicy else { error = "Update the helper before changing authentication requirements."; return }
        busy = "Checking authentication settings…"; error = nil; generation += 1
        let intent = generation
        changed()
        service.status { [weak self] response in
            guard let self else { return }
            guard self.generation == intent else { self.busy = nil; self.changed(); self.finishPendingStop(); return }
            self.accept(response)
            guard response.ok, response.protocolVersion >= 2 else {
                self.busy = nil; self.error = "The helper does not support this setting yet."; self.changed(); return
            }
            if response.authenticationRequired == required { self.busy = nil; self.changed(); return }
            let save: (GateOutcome) -> Void = { [weak self] outcome in
                guard let self else { return }
                guard self.generation == intent else { self.busy = nil; self.changed(); self.finishPendingStop(); return }
                switch outcome {
                case .cancelled: self.busy = nil; self.changed()
                case .failed(let message): self.busy = nil; self.error = message; self.changed()
                case .success:
                    self.busy = "Saving authentication setting…"; self.changed()
                    self.service.setAuthenticationRequired(required, policyRevision: response.policyRevision) { [weak self] saved in
                        guard let self else { return }
                        self.busy = nil; self.accept(saved); self.changed(); self.finishPendingStop()
                    }
                }
            }
            if required { save(.success) }
            else {
                self.busy = "Confirm prompt-free Keep awake…"; self.changed()
                self.authentication.authenticate(self.settings.authentication, reply: save)
            }
        }
    }
    private func finishPendingStop() {
        if quitRequested { quit() }
        else if stopRequested { stop(interactive: false) }
    }
    private func updatePolicy() {
        guard var config = configuration else { evaluateFollow(); return }
        config.mode = settings.mode; config.batteryFloor = settings.batteryFloor; config.displayAwake = settings.displayAwake
        if config.mode != .manual && power.isAC != true { stop(interactive: false) }
        else { startSession(config) }
    }
    func recordShortcut() {
        guard !preview, !isolated else { return }
        recordingShortcut = true
        _ = shortcut?.register(nil)
        shortcut?.record { [weak self] result, message in
            guard let self else { return }
            if let message { self.error = message; return }
            self.recordingShortcut = false
            guard let result else { _ = self.shortcut?.register(self.settings.shortcut); return }
            if let message = self.shortcut?.register(result) {
                self.error = message; _ = self.shortcut?.register(self.settings.shortcut)
            } else { self.settings.shortcut = result; self.persist() }
        }
    }
    func cancelShortcutRecording() {
        let wasRecording = recordingShortcut
        shortcut?.cancelRecording(); recordingShortcut = false
        if wasRecording { _ = shortcut?.register(settings.shortcut) }
    }
    func removeShortcut() { _ = shortcut?.register(nil); settings.shortcut = nil; persist() }
    func changeNotifications(_ value: Bool) {
        settings.notify = value; persist()
        if value, !preview, !isolated, Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        }
    }
    func changeLogin(_ value: Bool) {
        guard !preview, !isolated else { return }
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus(); persist()
        } catch { self.error = "Could not update launch at login: \(error.localizedDescription)"; refreshLoginStatus() }
    }
    func refreshLoginStatus() {
        guard !preview, !isolated else { return }
        let status = SMAppService.mainApp.status
        settings.launchAtLogin = status == .enabled
        loginStatus = status == .requiresApproval ? "Approval needed in System Settings → Login Items." : ""
    }
    private func persist() {
        guard !preview, !isolated else { return }
        if !SettingsStore.save(settings, to: SettingsStore.defaultURL()) { error = "Settings could not be saved." }
    }
    private func changed() { onChange?() }
    private func notify(_ text: String) {
        guard !preview, !isolated, settings.notify, Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { state in
            guard state.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent(); content.title = "Vaken"; content.body = text
            center.add(.init(identifier: "vaken-state", content: content, trigger: nil))
        }
    }
}

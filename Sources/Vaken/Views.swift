import AppKit
import ServiceManagement
import SwiftUI
import VakenCore

private let warmAccent = Color(red: 0.78, green: 0.46, blue: 0.12)

private struct InlineError: View {
    let message: String
    var action: (title: String, perform: () -> Void)?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.system(size: 11)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let action { Button(action.title, action: action.perform).controlSize(.small) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct VakenPopover: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater = AppUpdater()
    var settings: () -> Void
    @State private var more = false

    private var awake: Bool { model.flag == true }
    private var canStart: Bool { model.ready && model.busy == nil && !model.updateInProgress }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(nsImage: VakenArtwork.appIcon(size: 22))
                    .resizable().frame(width: 22, height: 22).accessibilityHidden(true)
                Text("Vaken").font(.system(size: 14, weight: .semibold))
            }

            statusCard

            if model.ready {
                modePicker
                timers
            } else {
                setup
            }

            if let error = model.error {
                InlineError(message: error, action: error.contains("Settings") ? ("Open Settings", settings) : nil)
            }
            if model.updateInProgress {
                Text("Finish or dismiss the update before starting Keep awake.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Divider()
            HStack(spacing: 14) {
                Button(action: settings) { Image(systemName: "gearshape").font(.system(size: 14)) }
                    .keyboardShortcut(",").accessibilityIdentifier("open-settings")
                    .help("Settings…").accessibilityLabel("Settings")
                if updater.configured {
                    Button(action: updater.check) { Image(systemName: "arrow.down.circle").font(.system(size: 14)) }
                        .disabled(!updater.canCheck)
                        .help("Check for Updates…").accessibilityLabel("Check for Updates")
                }
                Spacer(minLength: 8)
                Button { model.quit() } label: { Text("Quit Vaken").fixedSize() }.keyboardShortcut("q")
            }
            .fixedSize(horizontal: false, vertical: true)
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeOut(duration: 0.2), value: awake)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: VakenArtwork.menuIcon(active: awake, error: model.flag == nil))
                    .renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 28, height: 28)
                    .foregroundStyle(awake ? warmAccent : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keep awake").font(.system(size: 14, weight: .semibold))
                    Text(model.busy != nil ? model.status : (model.flag == nil ? "Reading sleep state…" : (awake ? "Your Mac stays awake" : "Normal sleep allowed")))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 2)
                Toggle("Keep awake", isOn: Binding(get: { awake }, set: { model.setAwake($0) }))
                    .labelsHidden().toggleStyle(.switch).tint(warmAccent)
                    .disabled(!model.ready || model.busy != nil || model.flag == nil || model.updateInProgress)
                    .accessibilityIdentifier("keep-awake")
            }

            if awake {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let remaining = model.remaining {
                            Text(remaining).font(.system(size: 22, weight: .semibold).monospacedDigit())
                                .accessibilityLabel("Time remaining \(remaining)")
                        }
                        Text(model.sessionText ?? "No time limit").font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("+15 min", action: model.extendSession)
                    Button("End session") { model.setAwake(false) }
                }
                .controlSize(.small)
                .disabled(model.busy != nil || !model.ready)
            }

            Divider()
            HStack(spacing: 5) {
                Image(systemName: model.power.isAC == true ? "powerplug" : "battery.75percent")
                Text(model.powerText)
                Spacer(minLength: 0)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(awake ? warmAccent.opacity(0.1) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(awake ? warmAccent.opacity(0.35) : Color.primary.opacity(0.055)))
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Mode").foregroundStyle(.secondary)
                Spacer()
                Picker("Mode", selection: Binding(get: { model.settings.mode }, set: model.changeMode)) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 205)
                .disabled(model.busy != nil)
                .accessibilityIdentifier("dropdown-mode")
            }
            Text(model.policyText).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11))
    }

    private var timers: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(awake ? "Change timer" : "Start a timer")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if awake && model.deadline != nil {
                    Button("Remove time limit", action: model.removeDeadline)
                        .buttonStyle(.link).font(.system(size: 11))
                        .disabled(!canStart)
                }
            }
            HStack(spacing: 6) {
                ForEach([15, 30, 60, 120], id: \.self) { minutes in
                    Button { model.startMinutes(minutes) } label: {
                        Text(minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h").frame(maxWidth: .infinity)
                    }
                    .disabled(!canStart)
                }
                Button { more = true } label: { Text("More…").frame(maxWidth: .infinity) }
                    .popover(isPresented: $more) {
                        SessionOptions(model: model, dismiss: { more = false })
                    }
            }.controlSize(.small)
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("One-time setup", systemImage: "lock.shield")
                .font(.system(size: 12, weight: .semibold))
            Text(model.setupStatus.isEmpty ? "Vaken needs a small helper to manage sleep. macOS asks you to approve it once." : model.setupStatus)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: model.configureRestore) {
                HStack(spacing: 6) {
                    if model.checkingSetup { ProgressView().controlSize(.mini) }
                    Text("Set up helper…")
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(warmAccent).controlSize(.large)
            .disabled(model.busy != nil || model.checkingSetup)
            .accessibilityIdentifier("setup-restore")
        }
    }
}

enum SettingsSection: String, CaseIterable {
    case general = "General"
    case about = "About"
}

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.leading, 3)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.055)))
        }
    }
}

struct VakenSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater
    @State private var section: SettingsSection

    init(model: AppModel, updater: AppUpdater = AppUpdater(), section: SettingsSection = .general) {
        self.model = model
        self.updater = updater
        _section = State(initialValue: section)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings section", selection: $section) {
                ForEach(SettingsSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 178)
            .accessibilityIdentifier("settings-section")
            .padding(.vertical, 14)
            Divider()
            if section == .general { general.padding(24) }
            else { about.padding(24) }
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var helperBanner: some View {
        let update = model.helperNeedsUpdate
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: update ? "exclamationmark.triangle.fill" : "lock.shield").foregroundStyle(warmAccent)
                Text(update ? "Helper update needed" : "Helper setup needed").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.busy != nil || model.checkingSetup { ProgressView().controlSize(.small) }
                Button(update ? "Update…" : "Set up…", action: model.configureRestore)
                    .buttonStyle(.borderedProminent).tint(warmAccent)
                    .disabled(model.busy != nil || model.checkingSetup)
                    .accessibilityLabel(update ? "Update Vaken helper" : "Set up Vaken helper")
                    .accessibilityIdentifier("settings-setup")
            }
            Text(update ? "End the current session, then update the helper to enable the authentication choice." : (model.setupStatus.isEmpty ? "One-time system approval lets Vaken manage sleep and restore it silently." : model.setupStatus))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(warmAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(warmAccent.opacity(0.35)))
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !model.ready || model.helperNeedsUpdate { helperBanner }
            if let error = model.error { InlineError(message: error) }

            SettingsCard(title: "Keep awake") {
                HStack {
                    Text("Mode")
                    Spacer()
                    Picker("Mode", selection: Binding(get: { model.settings.mode }, set: model.changeMode)) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 208)
                }
                Text(model.policyText).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack {
                    Text("Battery cutoff")
                    Spacer()
                    Picker("Battery cutoff", selection: Binding(get: { model.settings.batteryFloor }, set: model.changeFloor)) {
                        ForEach(Array(stride(from: 5, through: 50, by: 5)), id: \.self) { Text("\($0)%").tag($0) }
                    }.labelsHidden().frame(width: 85)
                }
                Text("Normal sleep resumes at this level or in Low Power Mode, while on battery.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard(title: "Authentication & helper") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Require Touch ID or password")
                        Text(model.authenticationRequired ? "Before each new Keep awake session. Turning this off asks once." : "New sessions start without a prompt.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("Require Touch ID or password before enabling", isOn: Binding(get: { model.authenticationRequired }, set: model.changeAuthenticationRequired))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(!model.supportsAuthenticationPolicy || model.busy != nil)
                        .accessibilityIdentifier("require-authentication")
                }
                Divider()
                HStack {
                    Text("Authenticate with")
                    Spacer()
                    Picker("Authentication", selection: Binding(get: { model.settings.authentication }, set: model.changeAuthentication)) {
                        ForEach(AuthenticationMethod.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 205)
                        .disabled(!model.authenticationRequired)
                }
                if model.ready && !model.helperNeedsUpdate {
                    Divider()
                    HStack {
                        Label("Helper connected", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                        Spacer()
                        if model.busy != nil || model.checkingSetup { ProgressView().controlSize(.small) }
                        Button("Check…", action: model.configureRestore)
                            .disabled(model.busy != nil || model.checkingSetup)
                            .accessibilityLabel("Check Vaken helper")
                            .accessibilityIdentifier("settings-setup")
                    }
                    if !model.setupStatus.isEmpty {
                        Text(model.setupStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            SettingsCard(title: "Preferences") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Keep display awake")
                        Text(model.settings.displayAwake ? "Only during a Keep awake session." : "Your screen sleeps and locks as usual.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Keep display awake", isOn: Binding(get: { model.settings.displayAwake }, set: model.changeDisplay)).labelsHidden()
                }
                Divider()
                HStack {
                    Text("Launch at login")
                    Spacer()
                    Toggle("Launch at login", isOn: Binding(get: { model.settings.launchAtLogin }, set: model.changeLogin)).labelsHidden()
                }
                if !model.loginStatus.isEmpty {
                    Text(model.loginStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
                Divider()
                HStack {
                    Text("State notifications")
                    Spacer()
                    Toggle("State notifications", isOn: Binding(get: { model.settings.notify }, set: model.changeNotifications)).labelsHidden()
                }
                Divider()
                HStack {
                    Text("Keyboard shortcut")
                    Spacer()
                    Button(model.recordingShortcut ? "Press shortcut…" : (model.settings.shortcut?.label ?? "Record…"), action: model.recordShortcut)
                    if model.settings.shortcut != nil { Button("Clear", action: model.removeShortcut) }
                    if model.recordingShortcut { Button("Cancel", action: model.cancelShortcutRecording) }
                }
            }.toggleStyle(.switch).controlSize(.small)
        }
        .font(.system(size: 12))
        .disabled(model.busy != nil)
        .onDisappear(perform: model.cancelShortcutRecording)
    }

    private var about: some View {
        VStack(spacing: 0) {
            Image(nsImage: VakenArtwork.appIcon(size: 104))
                .resizable().frame(width: 104, height: 104).accessibilityHidden(true)
                .padding(.top, 22)
            Text("Vaken").font(.system(size: 27, weight: .semibold)).padding(.top, 12)
            Text("Version \(AppInfo.version)").font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.top, 5).accessibilityIdentifier("about-version")
            VStack(spacing: 10) {
                if updater.configured {
                    Button("Check for Updates…", action: updater.check).disabled(!updater.canCheck)
                        .accessibilityIdentifier("check-updates")
                    Toggle("Automatically check for updates", isOn: Binding(get: { updater.automaticChecks }, set: updater.setAutomaticChecks))
                        .toggleStyle(.checkbox)
                }
                Text(updater.status).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.top, 16).frame(width: 300)
            Text("Keep your Mac awake. Let your screen rest.")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 22)
            Text("Made by \(AppInfo.author)")
                .font(.system(size: 12, weight: .medium)).padding(.top, 24)
                .accessibilityIdentifier("about-author")

            VStack(spacing: 10) {
                Link(destination: AppInfo.github) {
                    HStack {
                        Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }.padding(.horizontal, 14).padding(.vertical, 12)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }.accessibilityIdentifier("github-link")
                Link(destination: AppInfo.support) {
                    HStack {
                        Label("Buy me a coffee", systemImage: "cup.and.saucer")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }.padding(.horizontal, 14).padding(.vertical, 12)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }.accessibilityIdentifier("support-link")
            }
            .buttonStyle(.plain).font(.system(size: 12))
            .padding(.top, 24).frame(width: 280)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SessionOptions: View {
    @ObservedObject var model: AppModel
    let dismiss: () -> Void
    @State private var minutes = "45"
    @State private var end = Date().addingTimeInterval(3600)
    @State private var pid = ""
    @State private var selectedPID: Int32 = 0
    @State private var apps: [RunningAppChoice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Keep awake until…").font(.headline); Spacer(); Button("Done", action: dismiss) }
            HStack {
                Button("4 hours") { model.setAwake(true, duration: .hour4); dismiss() }
                Button("Until midnight") { model.setAwake(true, duration: .untilMidnight); dismiss() }
                Button("Indefinitely") { model.setAwake(true); dismiss() }
            }.controlSize(.small).disabled(!model.ready || model.busy != nil)
            HStack {
                TextField("Minutes", text: $minutes).frame(width: 65)
                Text("minutes")
                Spacer()
                Button("Start") {
                    guard let value = Int(minutes) else { model.error = "Enter a number of minutes."; return }
                    model.startMinutes(value); dismiss()
                }.disabled(!model.ready || model.busy != nil)
            }
            Divider()
            DatePicker("End at", selection: $end, displayedComponents: [.date, .hourAndMinute]).datePickerStyle(.field)
            HStack { Spacer(); Button("Start until this time") { model.startUntil(end); dismiss() }.disabled(!model.ready || model.busy != nil) }
            Divider()
            Picker("App exits", selection: $selectedPID) {
                Text("Choose running app…").tag(Int32(0))
                ForEach(apps) { Text($0.name).tag($0.pid) }
            }
            HStack {
                TextField("Or enter a process ID", text: $pid)
                Button("Start") {
                    let processID = Int32(pid.trimmingCharacters(in: .whitespaces)) ?? selectedPID
                    let name = apps.first { $0.pid == processID }?.name ?? "Process \(processID)"
                    model.startProcess(pid: processID, name: name); dismiss()
                }.disabled(!model.ready || model.busy != nil)
            }
            Text("Ends when that process exits. A background service staying open does not mean an agent is working.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18).frame(width: 355).font(.system(size: 12))
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != getpid() }
                .map { RunningAppChoice(pid: $0.processIdentifier, name: $0.localizedName ?? "App") }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}

private struct RunningAppChoice: Identifiable {
    let pid: Int32
    let name: String
    var id: Int32 { pid }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let updater = AppUpdater()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var allowTermination = false
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        let popoverHost = NSHostingController(rootView: VakenPopover(model: model, updater: updater, settings: showSettings))
        // Size the popover before it shows; growing afterwards pushes it up over the menu bar.
        popoverHost.sizingOptions = [.preferredContentSize]
        popover.contentViewController = popoverHost
        model.onChange = { [weak self] in self?.updateIcon() }
        model.onQuit = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.allowTermination = true
                if self.terminationPending {
                    self.terminationPending = false
                    NSApp.reply(toApplicationShouldTerminate: true)
                } else { NSApp.terminate(nil) }
            }
        }
        model.onQuitCancelled = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.terminationPending else { return }
                self.terminationPending = false
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
        updateIcon()
        model.start()
        updater.start(model: model)
    }

    private func updateIcon() {
        statusItem.button?.image = VakenArtwork.menuIcon(active: model.flag == true, error: model.error != nil || model.flag == nil)
        statusItem.button?.toolTip = "Vaken: \(model.status)"
        statusItem.button?.setAccessibilityLabel("Vaken, \(model.status)")
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            // A transient popover only closes on outside clicks while the app is active.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let host = NSHostingController(rootView: VakenSettings(model: model, updater: updater))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "Vaken Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        model.checkSetup()
        model.refreshLoginStatus()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if allowTermination { return .terminateNow }
        if !terminationPending { terminationPending = true; model.quit() }
        return .terminateLater
    }
}

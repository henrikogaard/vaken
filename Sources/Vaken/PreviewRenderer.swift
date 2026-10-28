import AppKit
import SwiftUI
import VakenCore

enum PreviewRenderer {
    static func render(to path: String) throws {
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for state in ["off", "on", "setup", "error", "authorizing"] {
                let model = AppModel(preview: true)
                model.flag = state == "on"
                model.power = PowerState(isAC: true, batteryPercent: 100)
                model.ready = state != "setup"
                model.helperProtocolVersion = 2
                if state == "on" { model.deadline = Date().addingTimeInterval(1795) }
                if state == "authorizing" { model.busy = "Waiting for Touch ID or password…" }
                if state == "error" { model.error = "Automatic restore failed. Open Settings to check its permission." }
                try capture(VakenPopover(model: model, settings: {}), width: 320,
                            to: root.appendingPathComponent("popover-\(state)-\(dark ? "dark" : "light").png"))
            }
            let model = AppModel(preview: true)
            model.flag = false
            model.ready = true
            model.helperProtocolVersion = 2
            model.power = PowerState(isAC: true, batteryPercent: 100)
            model.settings.shortcut = .init(keyCode: 40, modifiers: 0, label: "⌃⌥K")
            for section in SettingsSection.allCases {
                try capture(VakenSettings(model: model, section: section), width: 500,
                            to: root.appendingPathComponent("settings-\(section.rawValue.lowercased())-\(dark ? "dark" : "light").png"))
            }
            try capture(VakenSettings(model: model, updater: AppUpdater(previewConfigured: true), section: .about), width: 500,
                        to: root.appendingPathComponent("settings-updates-\(dark ? "dark" : "light").png"))
            try capture(VakenSettings(model: model, timerExpanded: true), width: 500,
                        to: root.appendingPathComponent("settings-timer-\(dark ? "dark" : "light").png"))
            try capture(SessionOptions(model: model, dismiss: {}), width: 355,
                        to: root.appendingPathComponent("session-options-\(dark ? "dark" : "light").png"))
            model.authenticationRequired = false
            try capture(VakenSettings(model: model), width: 500,
                        to: root.appendingPathComponent("settings-no-auth-\(dark ? "dark" : "light").png"))
            model.authenticationRequired = true
            model.helperProtocolVersion = 1
            try capture(VakenSettings(model: model), width: 500,
                        to: root.appendingPathComponent("settings-upgrade-\(dark ? "dark" : "light").png"))
            model.helperProtocolVersion = 2
            model.ready = false
            model.error = "Setup could not be completed. Try again."
            try capture(VakenSettings(model: model), width: 500,
                        to: root.appendingPathComponent("settings-setup-\(dark ? "dark" : "light").png"))
        }
    }

    private static func capture<V: View>(_ view: V, width: CGFloat, to url: URL) throws {
        let host = NSHostingView(rootView: view.fixedSize(horizontal: false, vertical: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSApp.appearance
        window.contentView = host
        host.setFrameSize(NSSize(width: width, height: 800))
        host.layoutSubtreeIfNeeded()
        let height = host.intrinsicContentSize.height
        window.setContentSize(NSSize(width: width, height: height))
        host.setFrameSize(NSSize(width: width, height: height))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        window.orderOut(nil)
    }
}

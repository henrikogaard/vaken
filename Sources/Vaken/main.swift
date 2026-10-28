import AppKit
import SwiftUI
import VakenCore

if CommandLine.arguments.contains("--version") {
    print(AppInfo.version)
    exit(0)
}
if CommandLine.arguments.contains("--build-number") {
    print(AppInfo.releaseBuild)
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--validate-updates"), CommandLine.arguments.count > index + 1 {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
        print(try UpdateConfiguration(info: info) == nil ? "Updates not configured" : "Update configuration valid")
        exit(0)
    } catch { fputs("Invalid update configuration.\n", stderr); exit(1) }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

if let index = CommandLine.arguments.firstIndex(of: "--render-previews"), CommandLine.arguments.count > index + 1 {
    try PreviewRenderer.render(to: CommandLine.arguments[index + 1])
} else if let index = CommandLine.arguments.firstIndex(of: "--render-assets"), CommandLine.arguments.count > index + 1 {
    try VakenArtwork.export(to: CommandLine.arguments[index + 1])
} else {
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}

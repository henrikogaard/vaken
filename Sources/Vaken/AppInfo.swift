import Foundation

enum AppInfo {
    /// The single editable release version. Packaging reads this via --version.
    static let releaseVersion = "0.3.2"
    static let releaseBuild = "5"
    static let author = "Henrik Øgård"
    static let github = URL(string: "https://github.com/henrikogaard")!
    static let support = URL(string: "https://buymeacoffee.com/henrikogaard")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? releaseVersion
    }
}

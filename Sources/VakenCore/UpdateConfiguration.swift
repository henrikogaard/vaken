import Foundation

public struct UpdateConfiguration {
    public let feedURL: URL
    public let publicKey: String
    public let build: String
    public enum Failure: Error { case invalidConfiguration }

    /// An absent pair is a local build, not a production endpoint.
    public init?(info: [String: Any]) throws {
        guard info["SUFeedURL"] != nil || info["SUPublicEDKey"] != nil else { return nil }
        guard let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              let key = info["SUPublicEDKey"] as? String,
              let bytes = Data(base64Encoded: key), bytes.count == 32,
              let build = info["CFBundleVersion"] as? String,
              !build.isEmpty, build.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = UInt64(build), number > 0 else { throw Failure.invalidConfiguration }
        feedURL = url; publicKey = key; self.build = build
    }
}

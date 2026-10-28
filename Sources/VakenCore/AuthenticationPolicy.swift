import Foundation
import Darwin

public struct AuthenticationPolicy: Codable, Equatable {
    public var required: Bool
    public var revision: Int64
    public init(required: Bool = true, revision: Int64 = 0) { self.required = required; self.revision = revision }
}

public struct AuthenticationPolicyStore {
    public enum Failure: Error { case invalidUser, staleRevision, untrustedPath, writeFailed }
    private let url: URL
    private let owner: UInt32
    public init(url: URL, owner: UInt32 = geteuid()) { self.url = url; self.owner = owner }

    private func trusted(_ path: URL, directory: Bool) -> Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path.path),
              (a[.ownerAccountID] as? NSNumber)?.uint32Value == owner,
              let permissions = a[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o022 == 0,
              a[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular) else { return false }
        return true
    }
    private func records() -> [String: AuthenticationPolicy] {
        guard trusted(url.deletingLastPathComponent(), directory: true), trusted(url, directory: false),
              let data = try? Data(contentsOf: url), data.count <= 65536,
              let values = try? JSONDecoder().decode([String: AuthenticationPolicy].self, from: data) else { return [:] }
        return values.filter { $0.value.revision >= 0 }
    }
    public func policy(for uid: UInt32) -> AuthenticationPolicy {
        guard uid > 0 else { return .init() }
        return records()[String(uid)] ?? .init()
    }
    @discardableResult public func set(required: Bool, for uid: UInt32, expectedRevision: Int64) throws -> AuthenticationPolicy {
        guard uid > 0 else { throw Failure.invalidUser }
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard trusted(parent, directory: true),
              !FileManager.default.fileExists(atPath: url.path) || trusted(url, directory: false) else { throw Failure.untrustedPath }
        var values = records()
        let current = values[String(uid)] ?? .init()
        guard current.revision == expectedRevision, current.revision < Int64.max else { throw Failure.staleRevision }
        let next = AuthenticationPolicy(required: required, revision: current.revision + 1)
        values[String(uid)] = next
        let data = try JSONEncoder().encode(values)
        guard data.count <= 65536 else { throw Failure.writeFailed }
        let temporary = parent.appendingPathComponent(".authentication-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw Failure.writeFailed }
        defer { if FileManager.default.fileExists(atPath: temporary.path) { try? FileManager.default.removeItem(at: temporary) } }
        guard rename(temporary.path, url.path) == 0 else { throw Failure.writeFailed }
        return next
    }
}

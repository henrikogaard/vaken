import Foundation
import VakenCore

public enum ServiceIdentity {
    public static let name = "no.ogard.vaken.helper"
    public static let plist = "no.ogard.vaken.helper.plist"
    public static let team = "45AD7E7G5G"
    public static let protocolVersion = 2
    public static func requirement(identifier: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\" and !(entitlement[\"com.apple.security.get-task-allow\"] exists) and !(entitlement[\"com.apple.security.cs.disable-library-validation\"] exists)"
    }
}

@objc public protocol SleepControlProtocol {
    func status(reply: @escaping (Data) -> Void)
    func begin(configuration: Data, reply: @escaping (Data) -> Void)
    func update(sessionID: String, configuration: Data, reply: @escaping (Data) -> Void)
    func heartbeat(sessionID: String, reply: @escaping (Data) -> Void)
    func restore(reply: @escaping (Data) -> Void)
    func beginWithPolicy(configuration: Data, policyRevision: Int64, reply: @escaping (Data) -> Void)
    func setAuthenticationRequired(_ required: Bool, policyRevision: Int64, reply: @escaping (Data) -> Void)
}

public struct ServiceReply: Codable {
    public var ok: Bool
    public var awake: Bool?
    public var sessionID: String?
    public var configuration: SessionConfiguration?
    public var message: String?
    public var protocolVersion: Int
    public var authenticationRequired: Bool
    public var policyRevision: Int64
    public init(ok: Bool = true, awake: Bool? = nil, sessionID: String? = nil,
                configuration: SessionConfiguration? = nil, message: String? = nil,
                protocolVersion: Int = ServiceIdentity.protocolVersion,
                authenticationRequired: Bool = true, policyRevision: Int64 = 0) {
        self.ok = ok; self.awake = awake; self.sessionID = sessionID
        self.configuration = configuration; self.message = message
        self.protocolVersion = protocolVersion; self.authenticationRequired = authenticationRequired; self.policyRevision = policyRevision
    }
    private enum CodingKeys: String, CodingKey { case ok, awake, sessionID, configuration, message, protocolVersion, authenticationRequired, policyRevision }
    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        ok = try v.decode(Bool.self, forKey: .ok)
        awake = try v.decodeIfPresent(Bool.self, forKey: .awake)
        sessionID = try v.decodeIfPresent(String.self, forKey: .sessionID)
        configuration = try v.decodeIfPresent(SessionConfiguration.self, forKey: .configuration)
        message = try v.decodeIfPresent(String.self, forKey: .message)
        protocolVersion = try v.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        authenticationRequired = true; policyRevision = 0
        if protocolVersion == ServiceIdentity.protocolVersion, let required = try v.decodeIfPresent(Bool.self, forKey: .authenticationRequired),
           let revision = try v.decodeIfPresent(Int64.self, forKey: .policyRevision), revision >= 0 {
            authenticationRequired = required; policyRevision = revision
        } else { protocolVersion = 1 }
    }
    public var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

public protocol SleepServicing: AnyObject {
    func status(_ reply: @escaping (ServiceReply) -> Void)
    func begin(_ configuration: SessionConfiguration, policyRevision: Int64?, reply: @escaping (ServiceReply) -> Void)
    func update(_ id: String, configuration: SessionConfiguration, reply: @escaping (ServiceReply) -> Void)
    func heartbeat(_ id: String, reply: @escaping (ServiceReply) -> Void)
    func restore(_ reply: @escaping (ServiceReply) -> Void)
    func setAuthenticationRequired(_ required: Bool, policyRevision: Int64, reply: @escaping (ServiceReply) -> Void)
    func disconnect()
}

import Foundation
import VakenCore
import VakenService

final class HelperClient: SleepServicing {
    private var connection: NSXPCConnection?
    private let lock = NSLock()
    private func proxy(error: @escaping (Error) -> Void) -> SleepControlProtocol? {
        lock.lock(); defer { lock.unlock() }
        if connection == nil {
            let c = NSXPCConnection(machServiceName: ServiceIdentity.name, options: .privileged)
            c.setCodeSigningRequirement(ServiceIdentity.requirement(identifier: ServiceIdentity.name))
            c.remoteObjectInterface = NSXPCInterface(with: SleepControlProtocol.self)
            c.invalidationHandler = { [weak self, weak c] in
                self?.lock.lock(); defer { self?.lock.unlock() }
                if self?.connection === c { self?.connection = nil }
            }
            c.resume(); connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler(error) as? SleepControlProtocol
    }
    private func call(_ reply: @escaping (ServiceReply) -> Void,
                      action: (SleepControlProtocol, @escaping (Data) -> Void) -> Void) {
        let completion = ReplyOnce(reply)
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
            completion.finish(.init(ok: false, message: "The helper did not respond. Check setup in Settings."))
        }
        guard let proxy = proxy(error: { _ in completion.finish(.init(ok: false, message: "The helper is unavailable. Enable it in Settings.")) }) else {
            completion.finish(.init(ok: false, message: "The helper is unavailable.")); return
        }
        action(proxy) { data in
            guard data.count <= 8192, let result = try? JSONDecoder().decode(ServiceReply.self, from: data) else {
                completion.finish(.init(ok: false, message: "Invalid helper response.")); return
            }
            completion.finish(result)
        }
    }
    func status(_ reply: @escaping (ServiceReply) -> Void) { call(reply) { $0.status(reply: $1) } }
    func begin(_ configuration: SessionConfiguration, policyRevision: Int64?, reply: @escaping (ServiceReply) -> Void) {
        guard let data = try? JSONEncoder().encode(configuration) else { reply(.init(ok: false, message: "Invalid session.")); return }
        call(reply) { proxy, callback in
            if let policyRevision { proxy.beginWithPolicy(configuration: data, policyRevision: policyRevision, reply: callback) }
            else { proxy.begin(configuration: data, reply: callback) }
        }
    }
    func update(_ id: String, configuration: SessionConfiguration, reply: @escaping (ServiceReply) -> Void) {
        guard let data = try? JSONEncoder().encode(configuration) else { reply(.init(ok: false, message: "Invalid session.")); return }
        call(reply) { $0.update(sessionID: id, configuration: data, reply: $1) }
    }
    func heartbeat(_ id: String, reply: @escaping (ServiceReply) -> Void) { call(reply) { $0.heartbeat(sessionID: id, reply: $1) } }
    func restore(_ reply: @escaping (ServiceReply) -> Void) { call(reply) { $0.restore(reply: $1) } }
    func setAuthenticationRequired(_ required: Bool, policyRevision: Int64, reply: @escaping (ServiceReply) -> Void) {
        call(reply) { $0.setAuthenticationRequired(required, policyRevision: policyRevision, reply: $1) }
    }
    func disconnect() {
        lock.lock(); let old = connection; connection = nil; lock.unlock()
        old?.invalidate()
    }
}

private final class ReplyOnce {
    private let lock = NSLock()
    private var reply: ((ServiceReply) -> Void)?
    init(_ reply: @escaping (ServiceReply) -> Void) { self.reply = reply }
    func finish(_ value: ServiceReply) {
        lock.lock(); let callback = reply; reply = nil; lock.unlock()
        if let callback { DispatchQueue.main.async { callback(value) } }
    }
}

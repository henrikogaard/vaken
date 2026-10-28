import Foundation
import LocalAuthentication
import Security
import VakenCore

protocol UserAuthenticating {
    func authenticate(_ method: AuthenticationMethod, reply: @escaping (GateOutcome) -> Void)
    func cancel()
}

final class NativeAuthentication: UserAuthenticating {
    private var context: LAContext?
    func cancel() { context?.invalidate(); context = nil }
    func authenticate(_ method: AuthenticationMethod, reply: @escaping (GateOutcome) -> Void) {
        if method == .password {
            DispatchQueue.global(qos: .userInitiated).async {
                var authorization: AuthorizationRef?
                var status = AuthorizationCreate(nil, nil, [], &authorization)
                if status == errAuthorizationSuccess, let authorization {
                    status = "system.privilege.admin".withCString { name in
                        var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
                        return withUnsafeMutablePointer(to: &item) { pointer in
                            var rights = AuthorizationRights(count: 1, items: pointer)
                            return AuthorizationCopyRights(authorization, &rights, nil,
                                [.interactionAllowed, .extendRights, .preAuthorize], nil)
                        }
                    }
                    AuthorizationFree(authorization, [.destroyRights])
                }
                let outcome: GateOutcome = status == errAuthorizationSuccess ? .success :
                    (status == errAuthorizationCanceled ? .cancelled : .failed("Administrator authorization failed."))
                DispatchQueue.main.async { reply(outcome) }
            }
            return
        }
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = "Use Password"
        self.context = context
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            reply(.failed(error?.localizedDescription ?? "Authentication is unavailable. Choose administrator password in Settings.")); return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Allow Vaken to keep this Mac awake.") { success, error in
            let outcome: GateOutcome
            if success { outcome = .success }
            else if let code = (error as? LAError)?.code, [.userCancel, .appCancel, .systemCancel].contains(code) { outcome = .cancelled }
            else { outcome = .failed(error?.localizedDescription ?? "Authentication failed.") }
            DispatchQueue.main.async { self.context = nil; reply(outcome) }
        }
    }
}

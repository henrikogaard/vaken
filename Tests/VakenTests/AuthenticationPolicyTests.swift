import XCTest
import VakenCore
import VakenService

final class AuthenticationPolicyTests: XCTestCase {
    private func fixture(_ body: (URL, AuthenticationPolicyStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencode/vaken-policy-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("authentication.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(url, AuthenticationPolicyStore(url: url))
    }
    func testDefaultAndPerUserPersistence() throws {
        try fixture { url, store in
            XCTAssertEqual(store.policy(for: 501), .init())
            try store.set(required: false, for: 501, expectedRevision: 0)
            XCTAssertEqual(AuthenticationPolicyStore(url: url).policy(for: 501), .init(required: false, revision: 1))
            XCTAssertEqual(store.policy(for: 502), .init())
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
            try store.set(required: true, for: 501, expectedRevision: 1)
            XCTAssertEqual(store.policy(for: 501), .init(required: true, revision: 2))
        }
    }
    func testCorruptAndWritablePolicyFailClosed() throws {
        try fixture { url, store in
            try store.set(required: false, for: 501, expectedRevision: 0)
            try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)
            XCTAssertTrue(store.policy(for: 501).required)
            XCTAssertThrowsError(try store.set(required: false, for: 501, expectedRevision: 0))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try Data("not json".utf8).write(to: url)
            XCTAssertTrue(store.policy(for: 501).required)
        }
    }
    func testStalePolicyRevisionCannotOverwriteNewerChoice() throws {
        try fixture { _, store in
            try store.set(required: false, for: 501, expectedRevision: 0)
            try store.set(required: true, for: 501, expectedRevision: 1)
            XCTAssertThrowsError(try store.set(required: false, for: 501, expectedRevision: 1))
            XCTAssertEqual(store.policy(for: 501), .init(required: true, revision: 2))
        }
    }
    func testWrongOwnerAndRootPolicyRejected() throws {
        try fixture { url, store in
            try store.set(required: false, for: 501, expectedRevision: 0)
            let wrongOwner = AuthenticationPolicyStore(url: url, owner: UInt32.max)
            XCTAssertTrue(wrongOwner.policy(for: 501).required)
            XCTAssertThrowsError(try wrongOwner.set(required: false, for: 501, expectedRevision: 0))
            XCTAssertThrowsError(try store.set(required: false, for: 0, expectedRevision: 0))
        }
    }
    func testOldAndIncompleteRepliesRequireAuthentication() throws {
        for json in [
            #"{"ok":true,"awake":false}"#,
            #"{"ok":true,"protocolVersion":2,"authenticationRequired":false}"#,
            #"{"ok":true,"protocolVersion":1,"authenticationRequired":false,"policyRevision":1}"#,
            #"{"ok":true,"protocolVersion":3,"authenticationRequired":false,"policyRevision":1}"#,
        ] {
            let reply = try JSONDecoder().decode(ServiceReply.self, from: Data(json.utf8))
            XCTAssertTrue(reply.authenticationRequired); XCTAssertEqual(reply.protocolVersion, 1)
        }
        let current = ServiceReply(awake: false, authenticationRequired: false, policyRevision: 2)
        let decoded = try JSONDecoder().decode(ServiceReply.self, from: current.data)
        XCTAssertFalse(decoded.authenticationRequired); XCTAssertEqual(decoded.policyRevision, 2)
    }
}

import Foundation

@main
struct FeishuCLITests {
    static var passed = 0
    static func expect(_ condition: Bool, _ name: String) {
        precondition(condition, name)
        passed += 1
        print("PASS: \(name)")
    }
    static func object(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    static func expectError(_ name: String, matching: (CLIError) -> Bool, body: () throws -> Void) {
        do { try body(); fatalError("Expected error: \(name)") }
        catch let error as CLIError { expect(matching(error), name) }
        catch { fatalError("Unexpected error: \(error)") }
    }
    static func main() throws {
        let missing: [String: Any] = ["identities": [
            "bot": ["status": "ready", "available": true],
            "user": ["status": "missing", "available": false, "openId": "original-user"]]]
        expect(!FeishuIdentity(missing).isReady, "bot readiness cannot enable user sync")
        let invalid: [String: Any] = ["identities": ["user": ["status": "ready", "available": true, "verified": false]]]
        expect(!FeishuIdentity(invalid).isReady, "server rejected user token stays disconnected")
        let authError: [String: Any] = ["ok": false, "error": ["type": "authentication", "subtype": "token_missing", "message": "need_user_authorization"]]
        expectError("expired/missing auth pauses the batch", matching: { $0.needsAuthorization }) {
            _ = try FeishuCLI.decode(stdout: object(authError), stderr: Data(), exitCode: 3)
        }
        let permissionError: [String: Any] = ["ok": false, "error": ["type": "permission", "message": "insufficient scopes"]]
        expectError("permission failures do not loop through authorization", matching: { !$0.needsAuthorization }) {
            _ = try FeishuCLI.decode(stdout: object(permissionError), stderr: Data(), exitCode: 4)
        }
        let plain = try FeishuCLI.decode(stdout: object(missing), stderr: Data(), exitCode: 0)
        expect(plain["identities"] != nil, "plain auth JSON works without API ok envelope")
        expectError("invalid auth links rejected", matching: { !$0.needsAuthorization }) {
            _ = try FeishuAuthorization(["device_code": "test", "verification_url": "file:///tmp/test"])
        }
        let url = "https://example.com/verify?flow_id=a%2Fb&user_code=A-B"
        let authorization = try FeishuAuthorization(["device_code": "success", "verification_url": url, "expires_in": 600])
        expect(authorization.url.absoluteString == url, "verification URL is preserved exactly")
        let batch = SyncBatch(items: [1, 2, 3])
        var needsAuth = true
        var visits: [Int] = []
        let operation: (Int) throws -> Void = { item in
            visits.append(item)
            if item == 2 && needsAuth { throw CLIError.authorizationRequired("expired") }
        }
        let first = batch.run(perform: operation, title: { String($0) }, progress: { _ in })
        expect(!first && batch.nextIndex == 1 && batch.succeeded == 1 && visits == [1, 2], "auth failure stops before remaining writes")
        needsAuth = false
        let resumed = batch.run(perform: operation, title: { String($0) }, progress: { _ in })
        expect(resumed && batch.succeeded == 3 && visits == [1, 2, 2, 3], "resume retries failed item and never replays successful items")
        let partial = SyncBatch(items: [1, 2, 3])
        _ = partial.run(perform: { if $0 == 2 { throw CLIError.failed("permission denied") } }, title: { String($0) }, progress: { _ in })
        expect(partial.succeeded == 2 && partial.failures.count == 1 && partial.nextIndex == 3, "ordinary failure retains batch results and continues")
        let cli = FeishuCLI(executable: CommandLine.arguments[1])
        let cancellation = CLICancellation()
        let started = try cli.beginAuthorization(cancellation: cancellation)
        let identity = try cli.finishAuthorization(started, cancellation: cancellation)
        expect(identity.isReady && identity.openID == "test-user", "device flow runs end to end and verifies user identity")
        let accountBatch = SyncBatch(items: [1])
        accountBatch.expectedOpenID = "different-user"
        expectError("different account never resumes a confirmed batch", matching: { !$0.needsAuthorization }) {
            try accountBatch.acceptIdentity(identity)
        }
        expect(accountBatch.nextIndex == 0, "account mismatch performs no calendar writes")
        let denied = try FeishuAuthorization(["device_code": "denied", "verification_url": url])
        expectError("authorization denial reaches the UI as failure", matching: { $0.needsAuthorization }) {
            _ = try cli.finishAuthorization(denied, cancellation: CLICancellation())
        }
        let large = try cli.call(["test-large-output"])
        expect((large["data"] as? String)?.count == 262144, "both output streams drain without pipe deadlock")
        expectError("stalled CLI times out", matching: { if case .timedOut = $0 { return true }; return false }) {
            _ = try cli.call(["test-wait"], timeout: 0.3)
        }
        let cancel = CLICancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { cancel.cancel() }
        expectError("cancel interrupts active device polling", matching: { if case .cancelled = $0 { return true }; return false }) {
            _ = try cli.call(["test-wait"], cancellation: cancel)
        }
        expectError("cancel before start launches no command", matching: { if case .cancelled = $0 { return true }; return false }) {
            _ = try cli.call(["test-wait"], cancellation: cancel)
        }
        print("\(passed) checks passed; no real calendar or credentials were used.")
    }
}

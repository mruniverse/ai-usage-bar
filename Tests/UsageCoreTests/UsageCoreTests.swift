import XCTest
@testable import UsageCore

final class UsageCoreTests: XCTestCase {
    func testParsesWindowsByDurationRatherThanPosition() throws {
        let data = #"{"rateLimits":{"primary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":2000000000},"secondary":{"usedPercent":12,"windowDurationMins":300}}}"#.data(using: .utf8)!
        let snapshot = try UsageSnapshot.decode(data)
        XCTAssertEqual(snapshot.windows.map(\.title), ["Sessão", "Semanal"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [12, 40])
        XCTAssertNil(snapshot.windows.first?.reset)
    }

    func testMissingWindowsStayMissing() throws {
        let data = #"{"rateLimits":{"primary":null,"secondary":null}}"#.data(using: .utf8)!
        XCTAssertTrue(try UsageSnapshot.decode(data).windows.isEmpty)
    }

    func testRejectsOutOfRangePercentage() throws {
        let data = #"{"rateLimits":{"primary":{"usedPercent":101}}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try UsageSnapshot.decode(data))
    }

    func testMalformedCodexResponseUsesProviderError() {
        XCTAssertThrowsError(try UsageSnapshot.decode(Data("not json".utf8))) { error in
            guard case ProviderError.invalidResponse = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testTimeoutIsBoundedWhenProcessIgnoresTermAndChildHoldsPipe() throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "#!/bin/sh\ntrap '' TERM\nsleep 2 &\nwait\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }
        let start = Date()
        XCTAssertThrowsError(try CodexClient().fetch(executable: script.path, timeout: 0.2)) { error in
            guard case ProviderError.timeout = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.2)
    }

    func testChangedAccountCannotLabelAnotherAccountsUsage() throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let body = """
        #!/bin/sh
        read x; printf '%s\\n' '{"id":1,"result":{}}'
        read x; printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt","planType":"plus","email":"first@example.invalid"}}}'
        read x; printf '%s\\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":20},"planType":"plus"}}}'
        read x; printf '%s\\n' '{"id":4,"result":{"account":{"type":"chatgpt","planType":"plus","email":"second@example.invalid"}}}'
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }
        XCTAssertThrowsError(try CodexClient().fetch(executable: script.path, timeout: 2)) { error in
            guard case ProviderError.unknownAccount = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testMissingAccountIdentityIsUnknown() throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let body = """
        #!/bin/sh
        read x; printf '%s\\n' '{"id":1,"result":{}}'
        read x; printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt","planType":"plus"}}}'
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }
        XCTAssertThrowsError(try CodexClient().fetch(executable: script.path, timeout: 2)) { error in
            guard case ProviderError.unknownAccount = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testFailureBackoffBlocksManualRetriesAndResetsOnSuccess() {
        var retry = RetryBackoff()
        let now = Date(timeIntervalSince1970: 1000)
        retry.failed(at: now)
        XCTAssertFalse(retry.canRetry(at: now.addingTimeInterval(29)))
        XCTAssertTrue(retry.canRetry(at: now.addingTimeInterval(30)))
        retry.failed(at: now.addingTimeInterval(30))
        XCTAssertFalse(retry.canRetry(at: now.addingTimeInterval(89)))
        XCTAssertTrue(retry.canRetry(at: now.addingTimeInterval(90)))
        retry.succeeded()
        XCTAssertTrue(retry.canRetry(at: now))
    }

    func testMissingCLIIsExplicit() {
        XCTAssertNil(CodexClient.findCLI(environment: ["PATH": "/nonexistent"], home: "/nonexistent"))
    }

    func testResetCountdown() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(ResetCountdown.text(reset: nil, now: now))
        XCTAssertNil(ResetCountdown.text(reset: now, now: now))
        XCTAssertNil(ResetCountdown.text(reset: now.addingTimeInterval(-1), now: now))
        XCTAssertEqual(ResetCountdown.text(reset: now.addingTimeInterval(1), now: now), "1min")
        XCTAssertEqual(ResetCountdown.text(reset: now.addingTimeInterval(90060), now: now), "1d 1h 1min")
    }

    func testCodexAccountSubscriptionValidation() throws {
        try CodexClient.validateAccount(type: "chatgpt", plan: "plus")
        try CodexClient.validateAccount(type: "chatgpt", plan: "pro")
        XCTAssertThrowsError(try CodexClient.validateAccount(type: "apiKey", plan: nil))
        XCTAssertThrowsError(try CodexClient.validateAccount(type: "chatgpt", plan: "free"))
        XCTAssertThrowsError(try CodexClient.validateAccount(type: "chatgpt", plan: nil))
        XCTAssertThrowsError(try CodexClient.validateAccount(type: "chatgpt", plan: "future"))
    }

    func testLiveCodexWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["AI_USAGE_LIVE_TEST"] == "1" else { throw XCTSkip("Teste real não solicitado") }
        let snapshot = try CodexClient().fetch()
        XCTAssertFalse(snapshot.windows.isEmpty, "Codex não retornou janelas")
    }
}

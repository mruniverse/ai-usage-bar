import XCTest
@testable import UsageCore

final class ProfileValidatorTests: XCTestCase {
    var tmp: TempDir!
    var claudeExe = ""
    var codexExe = ""
    let neighbor = ["CLAUDE_CONFIG_DIR": "/vizinho/claude", "CODEX_HOME": "/vizinho/codex", "PATH": "/usr/bin:/bin"]

    override func setUpWithError() throws {
        tmp = try TempDir()
        claudeExe = try tmp.writeScript("bin/claude", fakeClaudeScript)
        codexExe = try tmp.writeScript("bin/codex", fakeCodexScript)
    }

    func claudeProfile(_ name: String, state: String?) throws -> Profile {
        let dir = try tmp.makeDir("home/\(name)")
        if let state { try tmp.writeFile("home/\(name)/fake-state", state) }
        return Profile(nickname: name, provider: .claude, configDir: dir, executable: claudeExe)
    }
    func codexProfile(_ name: String, account: String?) throws -> Profile {
        let dir = try tmp.makeDir("home/\(name)")
        if let account { try tmp.writeFile("home/\(name)/fake-account", account) }
        return Profile(nickname: name, provider: .codex, configDir: dir, executable: codexExe)
    }
    func validator(timeout: TimeInterval = 5) -> ProfileValidator {
        ProfileValidator(baseEnvironment: neighbor, timeout: timeout, home: tmp.path)
    }

    // MARK: Claude — cada estado

    func testClaudeSubscriptionStates() throws {
        XCTAssertEqual(validator().validate(try claudeProfile("c1", state: "team")), .subscription(plan: "team"))
        XCTAssertEqual(validator().validate(try claudeProfile("c2", state: "max")), .subscription(plan: "max"))
    }
    func testClaudeLoggedOut() throws {
        XCTAssertEqual(validator().validate(try claudeProfile("c1", state: "loggedout")), .loggedOut)
        XCTAssertEqual(validator().validate(try claudeProfile("c2", state: nil)), .loggedOut)
    }
    func testClaudeApiKeyAndNonSubscriptionAreUnsupported() throws {
        XCTAssertEqual(validator().validate(try claudeProfile("c1", state: "apikey")), .unsupported(.apiKey))
        XCTAssertEqual(validator().validate(try claudeProfile("c2", state: "free")), .unsupported(.freePlan))
        XCTAssertEqual(validator().validate(try claudeProfile("c3", state: "notype")), .unsupported(.unverifiable))
    }
    func testClaudeGarbageOutputIsInvalidResponseNotLoggedIn() throws {
        XCTAssertEqual(validator().validate(try claudeProfile("c1", state: "garbage")), .failed(.invalidResponse))
    }
    func testClaudeHangIsBoundedByTimeoutAndKilled() throws {
        let profile = try claudeProfile("c1", state: "hang")
        let start = Date()
        XCTAssertEqual(validator(timeout: 0.3).validate(profile), .failed(.timeout))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }
    func testMissingCLIAndInvalidFolderAreDistinct() throws {
        var profile = try claudeProfile("c1", state: "team")
        profile.executable = tmp.path + "/bin/nao-existe"
        XCTAssertEqual(validator().validate(profile), .cliMissing)

        var bad = try claudeProfile("c2", state: "team")
        bad.configDir = tmp.path + "/home/nao-existe"
        XCTAssertEqual(validator().validate(bad), .folderInvalid)

        let file = try tmp.writeFile("home/arquivo", "x")
        bad.configDir = file
        XCTAssertEqual(validator().validate(bad), .folderInvalid)
    }
    func testCLILookupUsesPathThenFixedDirectories() throws {
        XCTAssertEqual(CLIFinder.find("claude", environment: ["PATH": tmp.path + "/bin:/usr/bin:/bin"], home: "/nonexistent"), claudeExe)
        var profile = try claudeProfile("c1", state: "team")
        profile.executable = nil
        let v = ProfileValidator(baseEnvironment: ["PATH": tmp.path + "/bin:/usr/bin:/bin"], timeout: 5, home: "/nonexistent")
        XCTAssertEqual(v.validate(profile), .subscription(plan: "team"))
    }

    // MARK: Codex — cada estado

    func testCodexStates() throws {
        XCTAssertEqual(validator().validate(try codexProfile("x1", account: "a")), .subscription(plan: "plus"))
        XCTAssertEqual(validator().validate(try codexProfile("x2", account: "none")), .loggedOut)
        XCTAssertEqual(validator().validate(try codexProfile("x3", account: "apikey")), .unsupported(.apiKey))
        XCTAssertEqual(validator().validate(try codexProfile("x4", account: "free")), .unsupported(.freePlan))
        var missing = try codexProfile("x5", account: "a"); missing.executable = tmp.path + "/bin/nada"
        XCTAssertEqual(validator().validate(missing), .cliMissing)
        var bad = try codexProfile("x6", account: "a"); bad.configDir = tmp.path + "/home/nao-existe"
        XCTAssertEqual(validator().validate(bad), .folderInvalid)
        XCTAssertEqual(validator(timeout: 0.3).validate(try codexProfile("x7", account: "hang")), .failed(.timeout))
    }

    // MARK: isolamento de ambiente

    func testClaudeSubprocessGetsOwnConfigDirAndNeverNeighborVariables() throws {
        let p1 = try claudeProfile("kory", state: "team")
        let p2 = try claudeProfile("outro", state: "loggedout")
        XCTAssertEqual(validator().validate(p1), .subscription(plan: "team"))
        XCTAssertEqual(validator().validate(p2), .loggedOut)
        for p in [p1, p2] {
            XCTAssertEqual(try String(contentsOfFile: p.configDir + "/seen-claude-dir"), p.configDir)
            XCTAssertEqual(try String(contentsOfFile: p.configDir + "/seen-codex-home"), "", "CODEX_HOME do vizinho vazou")
        }
    }
    func testCodexSubprocessGetsOwnHomeAndNeverClaudeVariable() throws {
        let p = try codexProfile("x1", account: "a")
        XCTAssertEqual(validator().validate(p), .subscription(plan: "plus"))
        XCTAssertEqual(try String(contentsOfFile: p.configDir + "/seen-codex-home"), p.configDir)
        XCTAssertEqual(try String(contentsOfFile: p.configDir + "/seen-claude-dir"), "", "CLAUDE_CONFIG_DIR do vizinho vazou")
    }

    // MARK: mensagens

    func testEveryStateHasDistinctActionablePortugueseMessage() {
        let states: [ProfileConnection] = [.notChecked, .folderInvalid, .cliMissing, .loggedOut,
            .unsupported(.apiKey), .unsupported(.freePlan), .unsupported(.unverifiable),
            .subscription(plan: "team"), .failed(.timeout), .failed(.invalidResponse)]
        for provider in ProviderKind.allCases {
            let messages = states.map { $0.message(for: provider) }
            XCTAssertEqual(Set(messages).count, messages.count, "mensagens repetidas para \(provider)")
            XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
        }
        XCTAssertTrue(ProfileConnection.unsupported(.apiKey).message(for: .claude).contains("API"))
        XCTAssertTrue(ProfileConnection.loggedOut.needsLogin)
        XCTAssertFalse(ProfileConnection.cliMissing.needsLogin)
        XCTAssertTrue(ProfileConnection.subscription(plan: nil).isConnected)
        XCTAssertFalse(ProfileConnection.unsupported(.apiKey).isConnected)
    }

    /// Opcional: `AI_USAGE_LIVE_CLAUDE_DIR=$HOME/.claude-kory swift test --filter testLiveClaude`.
    /// Usa o `claude` real do PATH e imprime só o estado (nunca a saída bruta do CLI).
    func testLiveClaudeProfileWhenExplicitlyEnabled() throws {
        guard let dir = ProcessInfo.processInfo.environment["AI_USAGE_LIVE_CLAUDE_DIR"] else { throw XCTSkip("Teste real não solicitado") }
        let profile = Profile(nickname: "live", provider: .claude, configDir: dir)
        let state = ProfileValidator().validate(profile)
        print("LIVE_CLAUDE_STATE:", state)
        XCTAssertNotEqual(state, .folderInvalid)
        XCTAssertNotEqual(state, .cliMissing)
    }
}

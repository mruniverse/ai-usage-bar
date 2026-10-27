import XCTest
@testable import UsageCore

final class ClaudeUsageClientTests: XCTestCase {
    var tmp: TempDir!
    var exe = ""
    var workRoot: URL!
    let neighbor = ["CLAUDE_CONFIG_DIR": "/vizinho/claude", "CODEX_HOME": "/vizinho/codex", "PATH": "/usr/bin:/bin"]

    override func setUpWithError() throws {
        tmp = try TempDir()
        exe = try tmp.writeScript("bin/claude", fakeClaudeScript)
        workRoot = URL(fileURLWithPath: try tmp.makeDir("work"))
    }

    func profileDir(_ name: String, usage: String? = nil, mode: String? = nil) throws -> String {
        let dir = try tmp.makeDir("home/\(name)")
        if let usage { try tmp.writeFile("home/\(name)/fake-usage", usage) }
        if let mode { try tmp.writeFile("home/\(name)/fake-usage-mode", mode) }
        return dir
    }
    func client() -> ClaudeUsageClient { ClaudeUsageClient(workRoot: workRoot) }
    func fetch(_ dir: String, timeout: TimeInterval = 5) throws -> UsageSnapshot {
        try client().fetch(executable: exe, configDir: dir, baseEnvironment: neighbor, timeout: timeout,
                           now: ISO8601DateFormatter().date(from: "2026-10-27T18:00:00Z")!)
    }
    func read(_ dir: String, _ name: String) -> String { (try? String(contentsOfFile: dir + "/" + name, encoding: .utf8)) ?? "<ausente>" }
    func assertThrows(_ expected: ProviderError, _ body: () throws -> Any, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual("\(error)", "\(expected)", file: file, line: line)
        }
    }

    // MARK: caminho feliz e comando

    func testParsesRealSampleAndPassesExactArguments() throws {
        let dir = try profileDir("kory", usage: realUsageSample)
        let snapshot = try fetch(dir)
        XCTAssertEqual(snapshot.windows.map(\.title), ["Sessão", "Semanal"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [42, 28])
        XCTAssertEqual(read(dir, "usage-args"), "-p /usage --no-session-persistence")
        XCTAssertEqual(ClaudeUsageClient.arguments, ["-p", "/usage", "--no-session-persistence"])
    }

    func testRunsInEmptyTemporaryDirectoryRemovedAfterwards() throws {
        let dir = try profileDir("kory", usage: realUsageSample)
        _ = try fetch(dir)
        let cwd = read(dir, "usage-cwd").trimmingCharacters(in: .whitespacesAndNewlines)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        XCTAssertNotNil(realpath(workRoot.path, &buffer))
        let root = String(cString: buffer)   // `pwd -P` devolve o caminho real (/private/var/...)
        XCTAssertTrue(cwd.hasPrefix(root + "/aiusagebar-claude-"), "cwd inesperado: \(cwd)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cwd), "diretório temporário deveria ter sido removido")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workRoot.path), [])
    }

    func testTemporaryDirectoryIsRemovedAlsoOnFailureAndTimeout() throws {
        for mode in ["exit1", "hang", "stderr"] {
            let dir = try profileDir("p-\(mode)", usage: realUsageSample, mode: mode)
            XCTAssertThrowsError(try fetch(dir, timeout: 0.6))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workRoot.path), [], mode)
        }
    }

    func testEnvironmentHasOnlyOwnConfigDirAndNothingFromNeighbor() throws {
        let dir = try profileDir("kory", usage: realUsageSample)
        _ = try fetch(dir)
        XCTAssertEqual(read(dir, "usage-seen-claude-dir"), dir)
        XCTAssertEqual(read(dir, "usage-seen-codex-home"), "", "CODEX_HOME do vizinho vazou")
        let env = ClaudeUsageClient.environment(configDir: "/p", base: neighbor)
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/p")
        XCTAssertNil(env["CODEX_HOME"])
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin")
    }

    func testTwoProfilesAreIsolated() throws {
        let a = try profileDir("a", usage: "Current session: 10% used\nCurrent week (all models): 11% used")
        let b = try profileDir("b", usage: "Current session: 70% used")
        let sa = try fetch(a), sb = try fetch(b)
        XCTAssertEqual(sa.windows.map(\.usedPercent), [10, 11])
        XCTAssertEqual(sb.windows.map(\.usedPercent), [70])
        XCTAssertEqual(read(a, "usage-seen-claude-dir"), a)
        XCTAssertEqual(read(b, "usage-seen-claude-dir"), b)
        XCTAssertEqual(read(a, "usage-calls").split(separator: "\n").count, 1)
    }

    // MARK: falhas

    func testTimeoutThatIgnoresSIGTERMIsKilledWithSIGKILL() throws {
        let dir = try profileDir("hang", mode: "hang")
        let start = Date()
        assertThrows(.timeout) { try fetch(dir, timeout: 0.6) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let pid = Int32(read(dir, "usage-pid").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertGreaterThan(pid, 1)
        var dead = false
        for _ in 0..<40 { if kill(pid, 0) != 0 { dead = true; break }; usleep(50_000) }
        XCTAssertTrue(dead, "processo que ignora SIGTERM continuou vivo")
    }

    func testStderrIsNeverParsed() throws {
        let onlyStderr = try profileDir("e1", mode: "stderr")
        assertThrows(.unrecognizedFormat) { try fetch(onlyStderr) }
        let mixed = try profileDir("e2", usage: "Current session: 5% used", mode: "stderrmix")
        XCTAssertEqual(try fetch(mixed).windows.map(\.usedPercent), [5], "stderr não pode contaminar a leitura")
    }

    func testNonZeroExitFailsEvenWithValidLookingOutput() throws {
        let dir = try profileDir("x", usage: realUsageSample, mode: "exit1")
        assertThrows(.serviceError) { try fetch(dir) }
    }

    func testNonZeroExitWithLoginTextMapsToLoggedOut() throws {
        let dir = try profileDir("x", usage: "Not logged in · Please run /login", mode: "exit1")
        assertThrows(.disconnected) { try fetch(dir) }
    }

    func testUnrecognizedOrEmptyOutputIsNeverZeroPercent() throws {
        for (i, text) in ["", "Sessão atual: 42% usado", "Current session: 999% used"].enumerated() {
            let dir = try profileDir("u\(i)", usage: text)
            assertThrows(.unrecognizedFormat) { try fetch(dir) }
        }
    }

    func testApiKeyTextWithoutWindowsMapsToApiKeyState() throws {
        let dir = try profileDir("api", usage: "You are currently using an API key; /usage is only available for subscriptions")
        assertThrows(.apiKeyAccount) { try fetch(dir) }
    }

    func testMissingExecutableIsLaunchFailure() throws {
        let dir = try profileDir("x", usage: realUsageSample)
        assertThrows(.launchFailed) {
            try client().fetch(executable: tmp.path + "/bin/nao-existe", configDir: dir, baseEnvironment: neighbor, timeout: 2)
        }
    }

    // MARK: opcional, com o CLI real

    /// `AI_USAGE_LIVE_CLAUDE_DIR=$HOME/.claude-kory swift test --filter testLiveClaudeUsage`.
    /// Usa o `claude` real do PATH e imprime só a contagem de janelas, nunca os dados.
    func testLiveClaudeUsageWhenExplicitlyEnabled() throws {
        guard let dir = ProcessInfo.processInfo.environment["AI_USAGE_LIVE_CLAUDE_DIR"] else { throw XCTSkip("Teste real não solicitado") }
        guard let executable = CLIFinder.find("claude") else { throw XCTSkip("claude não encontrado") }
        let snapshot = try ClaudeUsageClient().fetch(executable: executable, configDir: dir)
        print("LIVE_CLAUDE_USAGE_WINDOWS:", snapshot.windows.count)
        XCTAssertFalse(snapshot.windows.isEmpty)
    }
}

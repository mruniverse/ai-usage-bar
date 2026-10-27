import XCTest
@testable import UsageCore

final class ProfileMonitorTests: XCTestCase {
    var tmp: TempDir!
    var claudeExe = "", codexExe = "", slowExe = ""
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        tmp = try TempDir()
        // `calls` conta invocações por perfil; o script lento detecta execuções sobrepostas.
        claudeExe = try tmp.writeScript("bin/claude", fakeClaudeScript.replacingOccurrences(
            of: "state=$(cat", with: "echo x >> \"$CLAUDE_CONFIG_DIR/calls\"\nstate=$(cat"))
        codexExe = try tmp.writeScript("bin/codex", fakeCodexScript.replacingOccurrences(
            of: "acct=$(cat", with: "echo x >> \"$CODEX_HOME/calls\"\nacct=$(cat"))
        slowExe = try tmp.writeScript("bin/slow-claude", """
        #!/bin/sh
        d=$(dirname "$0")
        mkdir "$d/lock" 2>/dev/null || echo overlap >> "$d/overlap-log"
        sleep 0.4
        rmdir "$d/lock" 2>/dev/null
        if [ "$1" = "-p" ]; then
          echo x >> "$CLAUDE_CONFIG_DIR/usage-calls"
          printf '%s\\n' 'Current session: 5% used'
        else
          echo x >> "$CLAUDE_CONFIG_DIR/calls"
          printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"team"}'
        fi
        """)
    }

    func monitor(timeout: TimeInterval = 5, usageTimeout: TimeInterval = 5) -> ProfileMonitor {
        ProfileMonitor(validator: ProfileValidator(baseEnvironment: ["PATH": "/usr/bin:/bin"], timeout: timeout,
                                                   usageTimeout: usageTimeout, home: tmp.path))
    }
    func claude(_ name: String, state: String?, exe: String? = nil) throws -> Profile {
        let dir = try tmp.makeDir("home/\(name)")
        if let state { try tmp.writeFile("home/\(name)/fake-state", state) }
        return Profile(id: name, nickname: name, provider: .claude, configDir: dir, executable: exe ?? claudeExe)
    }
    func codex(_ name: String, account: String) throws -> Profile {
        let dir = try tmp.makeDir("home/\(name)")
        try tmp.writeFile("home/\(name)/fake-account", account)
        return Profile(id: name, nickname: name, provider: .codex, configDir: dir, executable: codexExe)
    }
    func calls(_ p: Profile) -> Int {
        ((try? String(contentsOfFile: p.configDir + "/calls", encoding: .utf8)) ?? "").split(separator: "\n").count
    }
    // MARK: Codex: dois perfis sem mistura

    func testTwoCodexProfilesKeepIndependentData() throws {
        let a = try codex("a", account: "a"), b = try codex("b", account: "b")
        let m = monitor()
        _ = m.refresh(a, now: t0); _ = m.refresh(b, now: t0)
        XCTAssertEqual(m.state(for: a.id).snapshot?.windows.map(\.usedPercent), [20])
        XCTAssertEqual(m.state(for: b.id).snapshot?.windows.map(\.usedPercent), [70])
        XCTAssertEqual(m.state(for: a.id).connection, .subscription(plan: "plus"))
        XCTAssertEqual(m.state(for: a.id).updatedAt, t0)
    }

    func testCodexFailureClearsOldSnapshotAndNeverKeepsStaleDataFromAnotherLogin() throws {
        let a = try codex("a", account: "a")
        let m = monitor()
        _ = m.refresh(a, now: t0)
        XCTAssertNotNil(m.state(for: a.id).snapshot)
        try tmp.writeFile("home/a/fake-account", "none")
        _ = m.refresh(a, now: t0.addingTimeInterval(400))
        XCTAssertNil(m.state(for: a.id).snapshot)
        XCTAssertEqual(m.state(for: a.id).connection, .loggedOut)
    }

    // MARK: backoff e independência

    func testBackoffIsPerProfileAndBlocksRepeatedCalls() throws {
        let bad = try claude("bad", state: "loggedout"), good = try claude("good", state: "team")
        let m = monitor()
        _ = m.refresh(bad, now: t0); _ = m.refresh(good, now: t0)
        _ = m.refresh(bad, now: t0.addingTimeInterval(10))      // dentro dos 30 s: não executa
        _ = m.refresh(good, now: t0.addingTimeInterval(10))     // outro perfil não é afetado
        XCTAssertEqual(calls(bad), 1)
        XCTAssertEqual(calls(good), 2)
        XCTAssertEqual(m.state(for: bad.id).connection, .loggedOut)
        _ = m.refresh(bad, now: t0.addingTimeInterval(31))
        XCTAssertEqual(calls(bad), 2)
        // Após novo login, uma tentativa permitida reconecta e zera o backoff.
        try tmp.writeFile("home/bad/fake-state", "team")
        _ = m.refresh(bad, now: t0.addingTimeInterval(100))
        XCTAssertEqual(m.state(for: bad.id).connection, .subscription(plan: "team"))
        XCTAssertNil(m.state(for: bad.id).retryAt)
    }

    func testChangingProfileFolderInvalidatesItsState() throws {
        let a = try codex("a", account: "a"), other = try codex("other", account: "b")
        let m = monitor()
        _ = m.refresh(a, now: t0)
        XCTAssertNotNil(m.state(for: a.id).snapshot)
        var moved = a; moved.configDir = other.configDir
        m.invalidateIfChanged(moved)
        XCTAssertNil(m.state(for: a.id).snapshot)
        XCTAssertEqual(m.state(for: a.id).connection, .notChecked)
    }

    // MARK: uma consulta por vez

    func testQueriesNeverOverlapAcrossProfilesAndSameProfileIsNotDuplicated() throws {
        let p1 = try claude("p1", state: nil, exe: slowExe), p2 = try claude("p2", state: nil, exe: slowExe)
        let m = monitor()
        let group = DispatchGroup()
        for p in [p1, p2, p1, p1] {
            group.enter()
            DispatchQueue.global().async { _ = m.refresh(p, now: self.t0); group.leave() }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path + "/bin/overlap-log"), "consultas sobrepostas")
        XCTAssertEqual(calls(p2), 1)
        XCTAssertEqual(calls(p1), 1, "cliques repetidos no mesmo perfil não podem iniciar nova consulta")
        XCTAssertEqual(usageCalls(p1), 1); XCTAssertEqual(usageCalls(p2), 1)
    }

    func testRefreshAllSkipsHiddenAndHonorsPerCycleLimit() throws {
        let ps = [try claude("p1", state: "team"), try claude("p2", state: "team"), try claude("p3", state: "team"), try claude("hid", state: "team")]
        var list = ps; list[3].visible = false
        let m = monitor()
        let n = m.refreshAll(list, now: t0, maxPerCycle: 2, stagger: 0)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(list.map(calls), [1, 1, 0, 0])
    }

    // MARK: Claude: assinatura validada + /usage por perfil

    func usageCalls(_ p: Profile) -> Int {
        ((try? String(contentsOfFile: p.configDir + "/usage-calls", encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    func testClaudeSubscriptionProfileGetsWindowsFromUsageCommand() throws {
        let p = try claude("kory", state: "team")
        let m = monitor()
        _ = m.refresh(p, now: t0)
        let state = m.state(for: p.id)
        XCTAssertEqual(state.connection, .subscription(plan: "team"))
        XCTAssertEqual(state.snapshot?.windows.map(\.title), ["Sessão", "Semanal"])
        XCTAssertEqual(state.snapshot?.windows.map(\.usedPercent), [42, 28])
        XCTAssertEqual(state.snapshot?.plan, "team")
        XCTAssertEqual(state.updatedAt, t0)
        XCTAssertEqual(m.panelProfiles([p]).map(\.id), ["kory"])
    }

    func testUsageIsNeverQueriedForNonSubscriptionOrLoggedOutProfiles() throws {
        let profiles = try ["apikey", "free", "loggedout", "notype", "garbage"].map { try claude($0, state: $0) }
        let m = monitor()
        for p in profiles { _ = m.refresh(p, now: t0) }
        for p in profiles {
            XCTAssertEqual(usageCalls(p), 0, "\(p.id): /usage só roda para assinatura validada")
            XCTAssertNil(m.state(for: p.id).snapshot)
        }
        XCTAssertEqual(m.state(for: "apikey").connection, .unsupported(.apiKey))
        XCTAssertEqual(m.state(for: "loggedout").connection, .loggedOut)
    }

    func testTwoClaudeProfilesKeepIndependentUsageData() throws {
        let a = try claude("a", state: "team"), b = try claude("b", state: "team")
        try tmp.writeFile("home/a/fake-usage", "Current session: 10% used")
        try tmp.writeFile("home/b/fake-usage", "Current session: 80% used\nCurrent week (Opus): 9% used")
        let m = monitor()
        _ = m.refresh(a, now: t0); _ = m.refresh(b, now: t0)
        XCTAssertEqual(m.state(for: a.id).snapshot?.windows.map(\.usedPercent), [10])
        XCTAssertEqual(m.state(for: b.id).snapshot?.windows.map(\.usedPercent), [80, 9])
    }

    func testUnrecognizedFormatClearsDataAndBacksOffPerProfile() throws {
        let p = try claude("kory", state: "team"), other = try claude("other", state: "team")
        let m = monitor()
        _ = m.refresh(p, now: t0); _ = m.refresh(other, now: t0)
        XCTAssertNotNil(m.state(for: p.id).snapshot)
        try tmp.writeFile("home/kory/fake-usage", "Sessão atual: 42% usado")
        _ = m.refresh(p, now: t0.addingTimeInterval(400))
        XCTAssertNil(m.state(for: p.id).snapshot, "formato desconhecido nunca vira dado antigo nem 0%")
        XCTAssertEqual(m.state(for: p.id).connection, .failed(.unrecognizedFormat))
        XCTAssertNotNil(m.state(for: p.id).retryAt)
        XCTAssertNil(m.state(for: other.id).retryAt, "backoff é por perfil")
        let before = usageCalls(p)
        _ = m.refresh(p, now: t0.addingTimeInterval(410))           // dentro do backoff: nenhum subprocesso
        XCTAssertEqual(usageCalls(p), before)
        try tmp.writeFile("home/kory/fake-usage", "Current session: 1% used")
        _ = m.refresh(p, now: t0.addingTimeInterval(800))
        XCTAssertEqual(m.state(for: p.id).snapshot?.windows.map(\.usedPercent), [1])
        XCTAssertNil(m.state(for: p.id).retryAt)
    }

    func testUsageTimeoutIsBoundedAndMarkedAsFailure() throws {
        let p = try claude("kory", state: "team")
        try tmp.writeFile("home/kory/fake-usage-mode", "hang")
        let m = monitor(usageTimeout: 0.6)
        let start = Date()
        _ = m.refresh(p, now: t0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        XCTAssertEqual(m.state(for: p.id).connection, .failed(.timeout))
        XCTAssertNil(m.state(for: p.id).snapshot)
    }

    func testPanelShowsOnlyVisibleConnectedProfiles() throws {
        let ok = try claude("ok", state: "team"), out = try claude("out", state: "loggedout"), hid = try claude("hid", state: "team")
        var hidden = hid; hidden.visible = false
        let m = monitor()
        for p in [ok, out] { _ = m.refresh(p, now: t0) }
        let shown = m.panelProfiles([ok, out, hidden]).map(\.id)
        XCTAssertEqual(shown, ["ok"])
    }
}

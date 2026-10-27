import XCTest
@testable import UsageCore

final class ProfileDiscoveryTests: XCTestCase {
    func testSuggestsConfigFoldersAndIgnoresBackupsFilesAndSymlinks() throws {
        let tmp = try TempDir()
        for name in [".claude", ".claude-kory", ".codex", ".codex-trabalho",
                     ".claude-backup", ".claude.bak", ".claude-2026-old", ".codex_backup_1", ".claude-kory.orig", ".claude-copy",
                     ".claudefoo", ".config"] {
            try tmp.makeDir(name)
        }
        try tmp.writeFile(".claude.json", "{}")
        try tmp.writeFile(".claude.json.backup.123", "{}")
        try tmp.writeFile(".codex-arquivo", "não sou pasta")
        let target = try tmp.makeDir("alvo")
        try FileManager.default.createSymbolicLink(atPath: tmp.url.appendingPathComponent(".claude-link").path, withDestinationPath: target)

        let found = ProfileDiscovery.suggestions(home: tmp.path, existing: [])
        XCTAssertEqual(found.map { URL(fileURLWithPath: $0.configDir).lastPathComponent },
                       [".claude", ".claude-kory", ".codex", ".codex-trabalho"])
        XCTAssertEqual(found.map(\.provider), [.claude, .claude, .codex, .codex])
        XCTAssertEqual(found.map(\.suggestedNickname), ["Claude", "Claude kory", "Codex", "Codex trabalho"])
    }

    func testAlreadyActivatedProfilesAreNotSuggestedAgain() throws {
        let tmp = try TempDir()
        let kory = try tmp.makeDir(".claude-kory"); try tmp.makeDir(".codex")
        let existing = [Profile(nickname: "Kory", provider: .claude, configDir: kory)]
        let found = ProfileDiscovery.suggestions(home: tmp.path, existing: existing)
        XCTAssertEqual(found.map(\.suggestedNickname), ["Codex"])
    }

    func testDiscoveryNeverReadsCredentialContents() throws {
        let tmp = try TempDir()
        let dir = try tmp.makeDir(".claude-kory")
        let cred = try tmp.writeFile(".claude-kory/.credentials.json", "SECRET_SENTINEL", mode: 0o000)
        defer { chmod(cred, 0o600) }
        // Se a descoberta tentasse ler o arquivo (ou listar a pasta) com permissão 000, isso falharia/seria detectável.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir)
        defer { chmod(dir, 0o700) }
        let found = ProfileDiscovery.suggestions(home: tmp.path, existing: [])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].configDir, dir)
        XCTAssertFalse(String(describing: found).contains("SECRET_SENTINEL"))
    }

    func testMissingHomeYieldsNoSuggestions() {
        XCTAssertTrue(ProfileDiscovery.suggestions(home: "/nao/existe/" + UUID().uuidString, existing: []).isEmpty)
    }
}

import XCTest
@testable import UsageCore

final class ProfileStoreTests: XCTestCase {
    var tmp: TempDir!
    var baseDir: URL { tmp.url.appendingPathComponent("AppSupport/AIUsageBar") }

    override func setUpWithError() throws { tmp = try TempDir() }

    func makeStore() -> ProfileStore { ProfileStore(directory: baseDir, home: tmp.path) }

    // MARK: caminhos

    func testPathNormalizationIsStable() {
        XCTAssertEqual(ConfigPath.normalize("~/.claude-kory", home: "/Users/x"), "/Users/x/.claude-kory")
        XCTAssertEqual(ConfigPath.normalize("/a//b/./c/../d/", home: "/Users/x"), "/a/b/d")
        XCTAssertEqual(ConfigPath.normalize("/", home: "/Users/x"), "/")
        XCTAssertNil(ConfigPath.normalize("relativo/pasta", home: "/Users/x"))
        XCTAssertNil(ConfigPath.normalize("", home: "/Users/x"))
    }

    // MARK: arquivo, permissões, segredos

    func testFirstUseCreatesDefaultCodexProfileOnlyOnce() throws {
        let codexHome = try tmp.makeDir("home/.codex")
        let store = makeStore()
        try store.loadOrMigrate(defaultCodexHome: codexHome)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].nickname, "Codex")
        XCTAssertEqual(store.profiles[0].provider, .codex)
        XCTAssertEqual(store.profiles[0].configDir, codexHome)
        XCTAssertTrue(store.profiles[0].visible)
        // Usuário remove tudo: não recria.
        try store.remove(id: store.profiles[0].id)
        let again = makeStore()
        try again.loadOrMigrate(defaultCodexHome: codexHome)
        XCTAssertTrue(again.profiles.isEmpty)
    }

    func testPermissionsAreOwnerOnlyAndFileHasNoSecrets() throws {
        let store = makeStore()
        let dir = try tmp.makeDir("home/.claude-kory")
        try tmp.writeFile("home/.claude-kory/.credentials.json", #"{"accessToken":"SECRET_SENTINEL"}"#)
        _ = try store.add(provider: .claude, nickname: "Kory", configDir: dir, executable: "/opt/bin/claude")
        XCTAssertEqual(try posixMode(baseDir.path), 0o700)
        let file = baseDir.appendingPathComponent("profiles.json").path
        XCTAssertEqual(try posixMode(file), 0o600)
        let text = try String(contentsOfFile: file, encoding: .utf8)
        XCTAssertFalse(text.contains("SECRET_SENTINEL"))
        XCTAssertFalse(text.lowercased().contains("token"))
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        let entries = object["profiles"] as! [[String: Any]]
        XCTAssertEqual(Set(entries[0].keys), ["id", "nickname", "provider", "configDir", "executable", "visible"])
        // Nenhum arquivo temporário sobrando.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: baseDir.path)
        XCTAssertEqual(leftovers, ["profiles.json"])
    }

    func testLooseDirectoryPermissionsAreTightenedAndSymlinkRefused() throws {
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        _ = try makeStore().add(provider: .codex, nickname: "A", configDir: try tmp.makeDir("home/.codex"), executable: nil)
        XCTAssertEqual(try posixMode(baseDir.path), 0o700)

        let real = try tmp.makeDir("real")
        let link = tmp.url.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: real))
        let store = ProfileStore(directory: link, home: tmp.path)
        XCTAssertThrowsError(try store.add(provider: .codex, nickname: "B", configDir: try tmp.makeDir("home/.codex2"), executable: nil)) {
            XCTAssertEqual($0 as? ProfileStoreError, .insecureDirectory)
        }
    }

    func testRoundTripPreservesOrderAndFields() throws {
        let store = makeStore()
        let a = try store.add(provider: .claude, nickname: "Um", configDir: "/tmp/p1", executable: nil)
        let b = try store.add(provider: .codex, nickname: "Dois", configDir: "/tmp/p2", executable: "/x/codex")
        try store.setVisible(id: a.id, false)
        let loaded = makeStore()
        try loaded.load()
        XCTAssertEqual(loaded.profiles, [store.profiles[0], store.profiles[1]])
        XCTAssertEqual(loaded.profiles.map(\.id), [a.id, b.id])
        XCTAssertFalse(loaded.profiles[0].visible)
        XCTAssertEqual(loaded.profiles[1].executable, "/x/codex")
    }

    func testCorruptFileIsReportedNotOverwritten() throws {
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try "{ isso não é json".write(to: baseDir.appendingPathComponent("profiles.json"), atomically: true, encoding: .utf8)
        let store = makeStore()
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? ProfileStoreError, .corrupt) }
        XCTAssertThrowsError(try store.add(provider: .codex, nickname: "A", configDir: "/tmp/z", executable: nil))
        XCTAssertEqual(try String(contentsOf: baseDir.appendingPathComponent("profiles.json")), "{ isso não é json")
        try store.quarantineCorruptFile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: baseDir.appendingPathComponent("profiles.json").path))
        try store.load()
        XCTAssertTrue(store.profiles.isEmpty)
    }

    // MARK: operações

    func testDuplicateFolderIsRejectedEvenWithDifferentSpelling() throws {
        let store = makeStore()
        _ = try store.add(provider: .claude, nickname: "Kory", configDir: "/tmp/dup/", executable: nil)
        XCTAssertThrowsError(try store.add(provider: .claude, nickname: "Outro", configDir: "/tmp//dup/./", executable: nil)) {
            XCTAssertEqual($0 as? ProfileStoreError, .duplicate)
        }
        XCTAssertEqual(store.profiles.count, 1)
        // Mesmo caminho em outro provedor é perfil distinto.
        XCTAssertNoThrow(try store.add(provider: .codex, nickname: "Cx", configDir: "/tmp/dup", executable: nil))
    }

    func testInvalidInputsAreRejected() {
        let store = makeStore()
        XCTAssertThrowsError(try store.add(provider: .codex, nickname: "   ", configDir: "/tmp/a", executable: nil)) {
            XCTAssertEqual($0 as? ProfileStoreError, .invalidNickname)
        }
        XCTAssertThrowsError(try store.add(provider: .codex, nickname: "x\u{0007}y", configDir: "/tmp/a", executable: nil))
        XCTAssertThrowsError(try store.add(provider: .codex, nickname: String(repeating: "a", count: 61), configDir: "/tmp/a", executable: nil))
        XCTAssertThrowsError(try store.add(provider: .codex, nickname: "ok", configDir: "pasta/relativa", executable: nil)) {
            XCTAssertEqual($0 as? ProfileStoreError, .invalidPath)
        }
        XCTAssertThrowsError(try store.add(provider: .codex, nickname: "ok", configDir: "/tmp/a", executable: "relativo/codex")) {
            XCTAssertEqual($0 as? ProfileStoreError, .invalidPath)
        }
    }

    func testRenameHideReorderRemove() throws {
        let store = makeStore()
        let a = try store.add(provider: .claude, nickname: "A", configDir: "/tmp/a", executable: nil)
        let b = try store.add(provider: .claude, nickname: "B", configDir: "/tmp/b", executable: nil)
        let c = try store.add(provider: .codex, nickname: "C", configDir: "/tmp/c", executable: nil)
        try store.rename(id: a.id, to: "  Kory  ")
        XCTAssertEqual(store.profiles[0].nickname, "Kory")
        try store.move(id: c.id, to: 0)
        XCTAssertEqual(store.profiles.map(\.id), [c.id, a.id, b.id])
        try store.move(id: c.id, to: 99)
        XCTAssertEqual(store.profiles.map(\.id), [a.id, b.id, c.id])
        try store.setVisible(id: b.id, false)
        try store.remove(id: a.id)
        let reloaded = makeStore(); try reloaded.load()
        XCTAssertEqual(reloaded.profiles.map(\.id), [b.id, c.id])
        XCTAssertFalse(reloaded.profiles[0].visible)
        XCTAssertThrowsError(try store.rename(id: "inexistente", to: "x")) { XCTAssertEqual($0 as? ProfileStoreError, .notFound) }
    }

    func testRemovingProfileNeverTouchesItsConfigFolder() throws {
        let dir = try tmp.makeDir("home/.claude-kory")
        let cred = try tmp.writeFile("home/.claude-kory/.credentials.json", "{}")
        let store = makeStore()
        let p = try store.add(provider: .claude, nickname: "K", configDir: dir, executable: nil)
        try store.remove(id: p.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cred))
    }

    func testLoginCommandIsQuotedPerProvider() {
        let claude = Profile(id: "1", nickname: "K", provider: .claude, configDir: "/Users/x/.claude-kory", executable: nil, visible: true)
        XCTAssertEqual(LoginCommand.text(for: claude), "CLAUDE_CONFIG_DIR='/Users/x/.claude-kory' claude auth login")
        let spaced = Profile(id: "2", nickname: "K", provider: .codex, configDir: "/Users/x/it's here", executable: "/opt/my bin/codex", visible: true)
        XCTAssertEqual(LoginCommand.text(for: spaced), #"CODEX_HOME='/Users/x/it'\''s here' '/opt/my bin/codex' login"#)
    }
}

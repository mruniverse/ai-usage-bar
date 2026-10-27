import Foundation
import Darwin

public enum ProviderKind: String, Codable, CaseIterable {
    case claude, codex
    public var displayName: String { self == .claude ? "Claude Code" : "Codex" }
    public var configVariable: String { self == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME" }
    public var commandName: String { self == .claude ? "claude" : "codex" }
}

/// Metadados de um perfil. Jamais contém credenciais.
public struct Profile: Codable, Equatable, Identifiable {
    public var id: String
    public var nickname: String
    public var provider: ProviderKind
    public var configDir: String
    public var executable: String?
    public var visible: Bool
    public init(id: String = UUID().uuidString, nickname: String, provider: ProviderKind,
                configDir: String, executable: String? = nil, visible: Bool = true) {
        self.id = id; self.nickname = nickname; self.provider = provider
        self.configDir = configDir; self.executable = executable; self.visible = visible
    }
}

public enum ConfigPath {
    /// Caminho absoluto, sem `.`, `..`, barras repetidas ou barra final. Não resolve links simbólicos.
    public static func normalize(_ path: String, home: String) -> String? {
        var raw = path
        if raw == "~" { raw = home }
        else if raw.hasPrefix("~/") { raw = home + "/" + raw.dropFirst(2) }
        guard raw.hasPrefix("/"), !raw.contains("\0") else { return nil }
        var parts: [Substring] = []
        for part in raw.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }
}

public enum ProfileStoreError: Error, Equatable {
    case duplicate, invalidNickname, invalidPath, notFound, corrupt, insecureDirectory, writeFailed
    public var message: String {
        switch self {
        case .duplicate: return "Já existe um perfil para esta pasta."
        case .invalidNickname: return "Use um apelido de 1 a 60 caracteres, sem caracteres de controle."
        case .invalidPath: return "Caminho inválido. Escolha uma pasta ou arquivo com caminho completo."
        case .notFound: return "Perfil não encontrado."
        case .corrupt: return "O arquivo de perfis está ilegível. Ele não foi alterado."
        case .insecureDirectory: return "A pasta de dados do app não é segura (link ou de outro usuário)."
        case .writeFailed: return "Não foi possível salvar os perfis."
        }
    }
}

/// Persistência de perfis em `<diretório>/profiles.json` (dir 700, arquivo 600, escrita atômica).
public final class ProfileStore {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AIUsageBar")
    }
    public let directory: URL
    public let home: String
    public private(set) var profiles: [Profile] = []
    private var blocked = false
    private struct Envelope: Codable { var version: Int; var profiles: [Profile] }

    public init(directory: URL = ProfileStore.defaultDirectory, home: String = NSHomeDirectory()) {
        self.directory = directory; self.home = home
    }
    public var fileURL: URL { directory.appendingPathComponent("profiles.json") }

    // MARK: carregar

    /// Arquivo ausente = lista vazia. Arquivo ilegível lança `.corrupt` e bloqueia gravações.
    public func load() throws {
        var info = stat()
        guard lstat(fileURL.path, &info) == 0 else { profiles = []; blocked = false; return }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_size < 1_000_000,
              let data = try? Data(contentsOf: fileURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == 1 else { blocked = true; throw ProfileStoreError.corrupt }
        var seenIDs = Set<String>(), seenKeys = Set<String>()
        var clean: [Profile] = []
        for var profile in envelope.profiles {
            guard let dir = ConfigPath.normalize(profile.configDir, home: home), !profile.id.isEmpty,
                  seenIDs.insert(profile.id).inserted,
                  seenKeys.insert(profile.provider.rawValue + ":" + dir).inserted,
                  Self.validNickname(profile.nickname) != nil else { blocked = true; throw ProfileStoreError.corrupt }
            profile.configDir = dir
            clean.append(profile)
        }
        profiles = clean; blocked = false
        if info.st_mode & 0o077 != 0 { chmod(fileURL.path, 0o600) }
    }

    /// Primeiro uso (sem profiles.json): cria o perfil padrão "Codex". Se o arquivo existir, nunca recria.
    public func loadOrMigrate(defaultCodexHome: String) throws {
        var info = stat()
        if lstat(fileURL.path, &info) != 0 {
            guard let dir = ConfigPath.normalize(defaultCodexHome, home: home) else { throw ProfileStoreError.invalidPath }
            profiles = [Profile(nickname: "Codex", provider: .codex, configDir: dir)]
            blocked = false
            try save()
        } else { try load() }
    }

    public func quarantineCorruptFile() throws {
        let target = directory.appendingPathComponent("profiles.json.corrupt-\(Int(Date().timeIntervalSince1970))")
        guard Darwin.rename(fileURL.path, target.path) == 0 else { throw ProfileStoreError.writeFailed }
        profiles = []; blocked = false
    }

    // MARK: operações

    @discardableResult
    public func add(provider: ProviderKind, nickname: String, configDir: String, executable: String?) throws -> Profile {
        guard !blocked else { throw ProfileStoreError.corrupt }
        guard let name = Self.validNickname(nickname) else { throw ProfileStoreError.invalidNickname }
        guard let dir = ConfigPath.normalize(configDir, home: home) else { throw ProfileStoreError.invalidPath }
        let exe = try normalizedExecutable(executable)
        guard !profiles.contains(where: { $0.provider == provider && $0.configDir == dir }) else { throw ProfileStoreError.duplicate }
        let profile = Profile(nickname: name, provider: provider, configDir: dir, executable: exe)
        try commit(profiles + [profile])
        return profile
    }
    public func rename(id: String, to nickname: String) throws {
        guard let name = Self.validNickname(nickname) else { throw ProfileStoreError.invalidNickname }
        try update(id) { $0.nickname = name }
    }
    public func setVisible(id: String, _ visible: Bool) throws { try update(id) { $0.visible = visible } }
    public func setExecutable(id: String, _ executable: String?) throws {
        let exe = try normalizedExecutable(executable)
        try update(id) { $0.executable = exe }
    }
    public func remove(id: String) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw ProfileStoreError.notFound }
        var next = profiles; next.remove(at: index)
        try commit(next)
    }
    public func move(id: String, to destination: Int) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw ProfileStoreError.notFound }
        var next = profiles; let item = next.remove(at: index)
        next.insert(item, at: max(0, min(destination, next.count)))
        try commit(next)
    }

    // MARK: internos

    public static func validNickname(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }
    private func normalizedExecutable(_ executable: String?) throws -> String? {
        guard let executable, !executable.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let path = ConfigPath.normalize(executable, home: home) else { throw ProfileStoreError.invalidPath }
        return path
    }
    private func update(_ id: String, _ change: (inout Profile) -> Void) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw ProfileStoreError.notFound }
        var next = profiles; change(&next[index])
        try commit(next)
    }
    private func commit(_ next: [Profile]) throws {
        guard !blocked else { throw ProfileStoreError.corrupt }
        let previous = profiles
        profiles = next
        do { try save() } catch { profiles = previous; throw error }
    }

    private func prepareDirectory() throws {
        let path = directory.path
        var info = stat()
        if lstat(path, &info) != 0 {
            try? FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard mkdir(path, 0o700) == 0 || errno == EEXIST, lstat(path, &info) == 0 else { throw ProfileStoreError.writeFailed }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw ProfileStoreError.insecureDirectory }
        if info.st_mode & 0o077 != 0, chmod(path, 0o700) != 0 { throw ProfileStoreError.insecureDirectory }
    }

    private func save() throws {
        try prepareDirectory()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Envelope(version: 1, profiles: profiles)) else { throw ProfileStoreError.writeFailed }
        let temp = directory.appendingPathComponent(".profiles-\(UUID().uuidString).tmp").path
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ProfileStoreError.writeFailed }
        var ok = fchmod(fd, 0o600) == 0
        if ok {
            ok = data.withUnsafeBytes { buffer -> Bool in
                var offset = 0
                while offset < buffer.count {
                    let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
        }
        ok = ok && fsync(fd) == 0
        close(fd)
        guard ok, Darwin.rename(temp, fileURL.path) == 0 else { unlink(temp); throw ProfileStoreError.writeFailed }
    }
}

public enum LoginCommand {
    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    /// Comando que o usuário copia e executa no Terminal; o app nunca o executa.
    public static func text(for profile: Profile) -> String {
        let command = profile.executable.map(shellQuote) ?? profile.provider.commandName
        let verb = profile.provider == .claude ? "auth login" : "login"
        return "\(profile.provider.configVariable)=\(shellQuote(profile.configDir)) \(command) \(verb)"
    }
}

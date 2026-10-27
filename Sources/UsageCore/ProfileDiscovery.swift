import Foundation
import Darwin

public struct ProfileSuggestion: Equatable, Identifiable {
    public let provider: ProviderKind
    public let configDir: String
    public let suggestedNickname: String
    public var id: String { provider.rawValue + ":" + configDir }
}

/// Sugere pastas `~/.claude*` e `~/.codex*`. Usa apenas nomes e tipo (lstat) de entradas diretas do home:
/// não abre, lista nem lê nada dentro das pastas, então nunca toca em credenciais.
public enum ProfileDiscovery {
    private static let ignoredTokens: Set<String> = ["backup", "backups", "bak", "old", "orig", "copy", "tmp", "temp", "trash", "cache", "save", "saved", "archive"]

    public static func suggestions(home: String, existing: [Profile]) -> [ProfileSuggestion] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: home) else { return [] }
        let taken = Set(existing.map { $0.provider.rawValue + ":" + $0.configDir })
        var result: [ProfileSuggestion] = []
        for name in names.sorted() {
            guard let (provider, suffix) = classify(name), !isBackup(name) else { continue }
            let path = (home as NSString).appendingPathComponent(name)
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            guard let dir = ConfigPath.normalize(path, home: home), !taken.contains(provider.rawValue + ":" + dir) else { continue }
            let label = provider == .claude ? "Claude" : "Codex"
            result.append(ProfileSuggestion(provider: provider, configDir: dir,
                                            suggestedNickname: suffix.isEmpty ? label : "\(label) \(suffix)"))
        }
        return result.sorted { ($0.provider.rawValue, $0.configDir) < ($1.provider.rawValue, $1.configDir) }
    }

    private static func classify(_ name: String) -> (ProviderKind, String)? {
        for (prefix, provider) in [(".claude", ProviderKind.claude), (".codex", .codex)] {
            if name == prefix { return (provider, "") }
            if name.hasPrefix(prefix + "-") || name.hasPrefix(prefix + "_") {
                return (provider, String(name.dropFirst(prefix.count + 1)).replacingOccurrences(of: "_", with: " "))
            }
        }
        return nil
    }

    private static func isBackup(_ name: String) -> Bool {
        if name.hasSuffix("~") { return true }
        let tokens = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return tokens.contains { ignoredTokens.contains($0) }
    }
}

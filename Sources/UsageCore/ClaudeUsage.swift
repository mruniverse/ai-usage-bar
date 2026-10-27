import Foundation
import Darwin

/// Interpreta o texto de `claude -p "/usage"`. O formato NÃO é uma interface documentada como estável:
/// o parser é tolerante com linhas desconhecidas, mas estrito com o que reconhece (percentual inteiro 0–100).
/// Texto em outro idioma, vazio ou sem nenhuma janela reconhecida é `formato não reconhecido`, nunca 0%.
public enum ClaudeUsageParser {
    public static let sessionTitle = "Sessão"
    public static let weeklyTitle = "Semanal"

    /// `now` só serve para inferir o ano do reset; o resultado é determinístico para um mesmo `now`.
    public static func parse(_ text: String, now: Date = Date()) throws -> UsageSnapshot {
        var session: UsageWindow?, weekly: UsageWindow?
        var extras: [UsageWindow] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = collapse(stripEscapes(String(rawLine)))
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = String(line[..<colon])
            guard let kind = LabelKind(label) else { continue }   // linha desconhecida: ignorada
            let value = try parseValue(String(line[line.index(after: colon)...]), now: now)
            switch kind {
            case .session where session == nil: session = window(sessionTitle, value)
            case .weekly where weekly == nil: weekly = window(weeklyTitle, value)
            case .extra(let model):
                let title = "\(weeklyTitle) · \(model)"
                if !extras.contains(where: { $0.title == title }) { extras.append(window(title, value)) }
            default: break   // linha repetida: vale a primeira
            }
        }
        let windows = [session, weekly].compactMap { $0 } + extras
        guard !windows.isEmpty else { throw ProviderError.unrecognizedFormat }
        return UsageSnapshot(windows: windows, plan: nil)
    }

    /// Só para saída sem nenhuma janela: reconhece textos de login ausente / chave de API.
    /// Os textos exatos não foram observados; a validação por `claude auth status` já cobre esses estados antes.
    public static func classifyNonSubscription(_ text: String) -> ProviderError? {
        let lower = text.lowercased()
        if lower.contains("not logged in") || lower.contains("please run /login") || lower.contains("claude auth login") { return .disconnected }
        if lower.contains("api key") || lower.contains("pay-as-you-go") || lower.contains("api usage billing") { return .apiKeyAccount }
        return nil
    }

    // MARK: linhas

    private enum LabelKind {
        case session, weekly, extra(String)
        init?(_ label: String) {
            let lower = label.lowercased()
            if lower == "current session" { self = .session; return }
            guard lower.hasPrefix("current week ("), lower.hasSuffix(")") else { return nil }
            let inner = String(label.dropFirst("current week (".count).dropLast()).trimmingCharacters(in: .whitespaces)
            let clean = String(inner.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(40))
            guard !clean.isEmpty else { return nil }
            self = clean.lowercased() == "all models" ? .weekly : .extra(clean)
        }
    }

    private static func window(_ title: String, _ value: (percent: Int, reset: Date?)) -> UsageWindow {
        UsageWindow(title: title, usedPercent: value.percent, reset: value.reset)
    }

    /// "42% used · resets Oct 27 at 7:10pm (America/Sao_Paulo)". Percentual inválido lança; reset ilegível vira nil.
    private static func parseValue(_ text: String, now: Date) throws -> (percent: Int, reset: Date?) {
        guard let groups = match(#"^\s*([^%]*)%\s*used\b(.*)$"#, in: text, groups: 2) else { throw ProviderError.unrecognizedFormat }
        let digits = groups[0].trimmingCharacters(in: .whitespaces)
        guard digits.range(of: #"^[0-9]{1,3}$"#, options: .regularExpression) != nil,
              let percent = Int(digits), (0...100).contains(percent) else { throw ProviderError.unrecognizedFormat }
        var reset: Date?
        if let resetText = match(#"\bresets\s+(.+)$"#, in: groups[1], groups: 1)?.first { reset = parseReset(resetText, now: now) }
        return (percent, reset)
    }

    // MARK: reset

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// "Oct 27 at 7:10pm (America/Sao_Paulo)" ou "Nov 2 at 5pm (America/Sao_Paulo)", no fuso informado.
    /// O ano é inferido: vale o primeiro candidato (ano anterior, atual ou seguinte, no fuso informado) que não esteja
    /// mais de 1 dia no passado.
    static func parseReset(_ text: String, now: Date) -> Date? {
        let pattern = #"^([A-Za-z]{3,9})\.?\s+(\d{1,2})\s+at\s+(\d{1,2})(?::(\d{2}))?\s*([ap])\.?m\.?\s*\(([^()]+)\)\s*$"#
        guard let g = match(pattern, in: text, groups: 6, caseInsensitive: true),
              let month = months.firstIndex(of: String(g[0].lowercased().prefix(3)))?.advanced(by: 1),
              let day = Int(g[1]), let hour12 = Int(g[2]), (1...12).contains(hour12),
              let minute = g[3].isEmpty ? 0 : Int(g[3]), (0...59).contains(minute),
              let zone = TimeZone(identifier: g[5].trimmingCharacters(in: .whitespaces)) else { return nil }
        let hour = hour12 % 12 + (g[4].lowercased() == "p" ? 12 : 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let currentYear = calendar.component(.year, from: now)
        let earliest = now.addingTimeInterval(-86_400)
        for year in (currentYear - 1)...(currentYear + 1) {
            var parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
            parts.timeZone = zone
            guard let date = calendar.date(from: parts) else { continue }
            let back = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            guard back.month == month, back.day == day, back.hour == hour, back.minute == minute else { continue }   // ex.: 30 de fevereiro
            if date >= earliest { return date }
        }
        return nil
    }

    // MARK: utilidades

    private static func match(_ pattern: String, in text: String, groups: Int, caseInsensitive: Bool = true) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1...groups).map { i in m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)) }
    }

    private static func stripEscapes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" }).joined(separator: " ")
    }
}

/// Executa `claude -p "/usage" --no-session-persistence` para um perfil e interpreta o texto.
/// O app não edita arquivos do Claude Code nem lê credenciais; a pasta de trabalho é um diretório temporário vazio,
/// criado e removido aqui. A flag `--no-session-persistence` é obrigatória: sem ela o CLI grava um `.jsonl` por chamada.
public struct ClaudeUsageClient {
    public static let arguments = ["-p", "/usage", "--no-session-persistence"]
    public var workRoot: URL

    public init(workRoot: URL = FileManager.default.temporaryDirectory) { self.workRoot = workRoot }

    /// Ambiente do subprocesso: o herdado, sem `CLAUDE_CONFIG_DIR`/`CODEX_HOME` de qualquer vizinho, e só com a pasta do perfil.
    public static func environment(configDir: String, base: [String: String]) -> [String: String] {
        var env = base
        env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        env.removeValue(forKey: "CODEX_HOME")
        env["CLAUDE_CONFIG_DIR"] = configDir
        return env
    }

    public func fetch(executable: String, configDir: String, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                      timeout: TimeInterval = 30, now: Date = Date()) throws -> UsageSnapshot {
        let work = workRoot.appendingPathComponent("aiusagebar-claude-" + UUID().uuidString, isDirectory: true)
        guard mkdir(work.path, 0o700) == 0 else { throw ProviderError.launchFailed }
        defer { try? FileManager.default.removeItem(at: work) }
        let result = try ProcessRunner.run(executable: executable, arguments: Self.arguments,
                                           environment: Self.environment(configDir: configDir, base: baseEnvironment),
                                           timeout: timeout, currentDirectory: work)
        let text = String(decoding: result.output, as: UTF8.self)
        guard result.status == 0 else { throw Self.nonZeroError(text) }
        do { return try ClaudeUsageParser.parse(text, now: now) }
        catch ProviderError.unrecognizedFormat { throw ClaudeUsageParser.classifyNonSubscription(text) ?? ProviderError.unrecognizedFormat }
    }

    private static func nonZeroError(_ text: String) -> ProviderError {
        ClaudeUsageParser.classifyNonSubscription(text) ?? .serviceError
    }
}

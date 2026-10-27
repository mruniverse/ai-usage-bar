import Foundation
import Darwin

public enum CLIFinder {
    /// Procura no PATH herdado e em diretórios fixos (apps do Finder recebem outro PATH).
    public static func find(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                            home: String = NSHomeDirectory()) -> String? {
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return paths.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Executa um comando curto com timeout rígido (SIGKILL), stdin vazio, stderr descartado e saída limitada.
enum ProcessRunner {
    static func run(executable: String, arguments: [String], environment: [String: String],
                    timeout: TimeInterval, maxOutput: Int = 64 * 1024,
                    currentDirectory: URL? = nil) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ProviderError.launchFailed }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, min(timeout, 3600)) * 1_000_000_000)
        let fd = output.fileHandleForReading.fileDescriptor
        defer {
            try? output.fileHandleForReading.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw ProviderError.timeout }
            let millis = Int32(min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max)))
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, millis)
            if ready == 0 { throw ProviderError.timeout }
            if ready < 0 { if errno == EINTR { continue }; throw ProviderError.serviceError }
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw ProviderError.serviceError }
            data.append(contentsOf: buffer[0..<count])
            if data.count > maxOutput { throw ProviderError.invalidResponse }
        }
        while process.isRunning {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ProviderError.timeout }
            usleep(5_000)
        }
        return (process.terminationStatus, data)
    }
}

public enum UnsupportedReason: Equatable { case apiKey, freePlan, unverifiable }
public enum FailureReason: Equatable { case timeout, launch, invalidResponse, unrecognizedFormat, service }

/// Estado de conexão de um perfil. Cada caso tem mensagem própria e acionável.
public enum ProfileConnection: Equatable {
    case notChecked
    case folderInvalid
    case cliMissing
    case loggedOut
    case unsupported(UnsupportedReason)
    case subscription(plan: String?)
    case failed(FailureReason)

    public var isConnected: Bool { if case .subscription = self { return true }; return false }
    public var needsLogin: Bool { self == .loggedOut }

    public func message(for provider: ProviderKind) -> String {
        let cli = provider.displayName
        let account = provider == .claude ? "assinatura Claude (claude.ai)" : "assinatura ChatGPT"
        switch self {
        case .notChecked: return "Ainda não verificado."
        case .folderInvalid: return "A pasta não existe ou não é uma pasta. Escolha a pasta de configuração correta."
        case .cliMissing: return "\(cli) não encontrado. Instale o CLI ou informe o caminho do executável."
        case .loggedOut: return "Sem login neste perfil. Copie o comando abaixo e execute no Terminal."
        case .unsupported(.apiKey): return "Este perfil usa chave de API ou pagamento por uso, que não é suportado. Entre com uma \(account)."
        case .unsupported(.freePlan): return "Este perfil usa um plano gratuito, que não é suportado. Entre com uma \(account)."
        case .unsupported(.unverifiable): return "Não foi possível confirmar que é uma \(account). Por segurança, o perfil não é consultado."
        case .subscription(let plan):
            let suffix = plan.map { " (plano \($0))" } ?? ""
            return "Conectado como \(account)\(suffix)."
        case .failed(.timeout): return "A verificação demorou demais. O app tentará de novo em instantes."
        case .failed(.launch): return "Não foi possível iniciar o \(cli). Verifique o executável."
        case .failed(.invalidResponse): return "Resposta inesperada do \(cli). A versão do CLI pode ser incompatível."
        case .failed(.unrecognizedFormat): return "Formato da resposta do \(cli) não reconhecido (o texto do /usage mudou ou está em outro idioma). Nenhum dado é exibido."
        case .failed(.service): return "Falha ao consultar o \(cli). O app tentará de novo em instantes."
        }
    }
}

public struct ProfileValidator {
    public var baseEnvironment: [String: String]
    public var timeout: TimeInterval
    /// Limite da consulta `claude -p "/usage"` (inicia o CLI inteiro; mais lenta que `auth status`).
    public var usageTimeout: TimeInterval
    public var home: String

    public init(baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                timeout: TimeInterval = 15, usageTimeout: TimeInterval = 30, home: String = NSHomeDirectory()) {
        self.baseEnvironment = baseEnvironment; self.timeout = timeout; self.usageTimeout = usageTimeout; self.home = home
    }

    /// Ambiente do subprocesso: sem variáveis de configuração herdadas (de nenhum perfil vizinho) e só com a do próprio perfil.
    public func environment(for profile: Profile) -> [String: String] {
        var env = baseEnvironment
        env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        env.removeValue(forKey: "CODEX_HOME")
        env[profile.provider.configVariable] = profile.configDir
        return env
    }

    /// Verificações locais baratas, antes de qualquer subprocesso.
    func preflight(_ profile: Profile) -> (ProfileConnection?, executable: String?) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: profile.configDir, isDirectory: &isDir), isDir.boolValue else { return (.folderInvalid, nil) }
        if let explicit = profile.executable {
            return FileManager.default.isExecutableFile(atPath: explicit) ? (nil, explicit) : (.cliMissing, nil)
        }
        guard let found = CLIFinder.find(profile.provider.commandName, environment: baseEnvironment, home: home) else { return (.cliMissing, nil) }
        return (nil, found)
    }

    /// Valida login e tipo de assinatura (sem consultar limites).
    public func validate(_ profile: Profile) -> ProfileConnection {
        let (early, executable) = preflight(profile)
        if let early { return early }
        guard let executable else { return .cliMissing }
        switch profile.provider {
        case .claude: return validateClaude(profile, executable: executable)
        case .codex:
            do {
                let plan = try CodexClient().checkAccount(executable: executable, timeout: timeout, environment: environment(for: profile))
                return .subscription(plan: plan)
            } catch { return Self.map(error) }
        }
    }

    /// Codex: valida e consulta limites em uma só execução do app-server.
    public func queryCodex(_ profile: Profile) -> (connection: ProfileConnection, snapshot: UsageSnapshot?) {
        let (early, executable) = preflight(profile)
        if let early { return (early, nil) }
        guard let executable else { return (.cliMissing, nil) }
        do {
            let snapshot = try CodexClient().fetch(executable: executable, timeout: timeout, environment: environment(for: profile))
            return (.subscription(plan: snapshot.plan), snapshot)
        } catch { return (Self.map(error), nil) }
    }

    /// Claude: valida login/assinatura (`claude auth status`) e, só se for assinatura, consulta `claude -p "/usage"`.
    public func queryClaude(_ profile: Profile) -> (connection: ProfileConnection, snapshot: UsageSnapshot?) {
        let (early, executable) = preflight(profile)
        if let early { return (early, nil) }
        guard let executable else { return (.cliMissing, nil) }
        let connection = validateClaude(profile, executable: executable)
        guard connection.isConnected else { return (connection, nil) }
        do {
            let snapshot = try ClaudeUsageClient().fetch(executable: executable, configDir: profile.configDir,
                                                         baseEnvironment: baseEnvironment, timeout: usageTimeout)
            guard case .subscription(let plan) = connection else { return (connection, snapshot) }
            return (connection, UsageSnapshot(windows: snapshot.windows, plan: plan))
        } catch { return (Self.map(error), nil) }
    }

    static func map(_ error: Error) -> ProfileConnection {
        guard let error = error as? ProviderError else { return .failed(.service) }
        switch error {
        case .cliMissing: return .cliMissing
        case .disconnected: return .loggedOut
        case .apiKeyAccount: return .unsupported(.apiKey)
        case .unsupportedAccount: return .unsupported(.freePlan)
        case .unknownAccount: return .unsupported(.unverifiable)
        case .timeout: return .failed(.timeout)
        case .launchFailed: return .failed(.launch)
        case .invalidResponse: return .failed(.invalidResponse)
        case .unrecognizedFormat: return .failed(.unrecognizedFormat)
        case .serviceError: return .failed(.service)
        }
    }

    private func validateClaude(_ profile: Profile, executable: String) -> ProfileConnection {
        struct Auth: Decodable { let loggedIn: Bool?; let authMethod: String?; let subscriptionType: String? }
        let result: (status: Int32, output: Data)
        do { result = try ProcessRunner.run(executable: executable, arguments: ["auth", "status"],
                                            environment: environment(for: profile), timeout: timeout) }
        catch { return Self.map(error) }
        guard let auth = try? JSONDecoder().decode(Auth.self, from: result.output), let loggedIn = auth.loggedIn else {
            return .failed(result.output.isEmpty ? .service : .invalidResponse)
        }
        guard loggedIn else { return .loggedOut }
        let method = (auth.authMethod ?? "").lowercased()
        guard method == "claude.ai" else {
            let apiLike = ["api", "console", "bedrock", "vertex", "foundry"].contains { method.contains($0) }
            return .unsupported(apiLike ? .apiKey : .unverifiable)
        }
        let plan = (auth.subscriptionType ?? "").lowercased()
        if plan.contains("free") { return .unsupported(.freePlan) }
        guard ["pro", "max", "team", "enterprise"].contains(where: { plan.contains($0) }) else { return .unsupported(.unverifiable) }
        return .subscription(plan: plan)
    }
}

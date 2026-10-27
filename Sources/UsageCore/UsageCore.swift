import Foundation
import Darwin

public struct UsageWindow: Identifiable {
    public let id = UUID()
    public let title: String
    public let usedPercent: Int
    public let reset: Date?
}

public struct UsageSnapshot {
    public let windows: [UsageWindow]
    public let plan: String?
    public static func decode(_ data: Data) throws -> UsageSnapshot {
        struct Response: Decodable { let rateLimits: Limits }
        struct Limits: Decodable { let primary: Window?; let secondary: Window?; let planType: String? }
        struct Window: Decodable { let usedPercent: Int; let windowDurationMins: Int?; let resetsAt: TimeInterval? }
        let limits: Limits
        do { limits = try JSONDecoder().decode(Response.self, from: data).rateLimits }
        catch { throw ProviderError.invalidResponse }
        let windows = [limits.primary, limits.secondary].compactMap { $0 }.map { window -> UsageWindow in
            let duration = window.windowDurationMins
            let title: String
            if let duration, duration >= 10000 && duration <= 10200 { title = "Semanal" }
            else if let duration, duration > 0 && duration <= 360 { title = "Sessão" }
            else if let duration { title = "Janela de \(duration) min" }
            else { title = "Janela sem duração informada" }
            return UsageWindow(title: title, usedPercent: window.usedPercent, reset: window.resetsAt.map(Date.init(timeIntervalSince1970:)))
        }.sorted { ($0.title == "Sessão" ? 0 : 1) < ($1.title == "Sessão" ? 0 : 1) }
        guard windows.allSatisfy({ (0...100).contains($0.usedPercent) }) else { throw ProviderError.invalidResponse }
        return UsageSnapshot(windows: windows, plan: limits.planType)
    }
}

public enum ProviderError: Error, LocalizedError {
    case cliMissing, launchFailed, timeout, disconnected, apiKeyAccount, unsupportedAccount, unknownAccount, invalidResponse, unrecognizedFormat, serviceError
    public var errorDescription: String? {
        switch self {
        case .cliMissing: return "Codex CLI não encontrado. Instale-o e reabra o app."
        case .launchFailed: return "Não foi possível iniciar o Codex CLI."
        case .timeout: return "A consulta ao Codex expirou. Tente novamente."
        case .disconnected: return "Login Codex ausente. Execute codex login no Terminal."
        case .apiKeyAccount: return "A conta usa API key, que não é suportada. Entre com uma assinatura ChatGPT."
        case .unsupportedAccount: return "A conta atual não usa uma assinatura ChatGPT compatível."
        case .unknownAccount: return "Não foi possível identificar a conta ou confirmar sua assinatura ChatGPT."
        case .invalidResponse: return "Resposta do Codex inválida ou protocolo incompatível."
        case .unrecognizedFormat: return "Formato da resposta não reconhecido."
        case .serviceError: return "O Codex não conseguiu consultar os limites. Verifique login, rede e versão do CLI."
        }
    }
}

public struct RetryBackoff {
    private var failures = 0
    public private(set) var nextRetry: Date?
    public init() {}
    public func canRetry(at now: Date = Date()) -> Bool { nextRetry.map { now >= $0 } ?? true }
    public mutating func failed(at now: Date = Date()) {
        failures = min(failures + 1, 5)
        nextRetry = now.addingTimeInterval(min(300, 30 * pow(2, Double(failures - 1))))
    }
    public mutating func succeeded() { failures = 0; nextRetry = nil }
}

public struct CodexClient {
    public init() {}
    public static func validateAccount(type: String?, plan: String?) throws {
        guard let type else { throw ProviderError.unknownAccount }
        guard type == "chatgpt" else { throw ProviderError.apiKeyAccount }
        guard let plan else { throw ProviderError.unknownAccount }
        let supported = ["plus", "pro", "prolite", "team", "business", "enterprise", "edu"]
        if supported.contains(plan.lowercased()) { return }
        if ["free", "api", "unknown"].contains(plan.lowercased()) {
            if plan.lowercased() == "unknown" { throw ProviderError.unknownAccount }
            throw ProviderError.unsupportedAccount
        }
        throw ProviderError.unknownAccount
    }
    public static func findCLI(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) -> String? {
        CLIFinder.find("codex", environment: environment, home: home)
    }
    /// `environment` (quando informado) substitui por completo o ambiente do subprocesso; é assim que cada perfil recebe só o seu `CODEX_HOME`.
    public func fetch(executable: String? = nil, timeout: TimeInterval = 15, environment: [String: String]? = nil) throws -> UsageSnapshot {
        guard let snapshot = try run(executable: executable, timeout: timeout, environment: environment, accountOnly: false).snapshot else { throw ProviderError.invalidResponse }
        return snapshot
    }
    /// Somente `initialize` + `account/read`: valida login e tipo de assinatura sem consultar limites.
    public func checkAccount(executable: String? = nil, timeout: TimeInterval = 15, environment: [String: String]? = nil) throws -> String {
        guard let plan = try run(executable: executable, timeout: timeout, environment: environment, accountOnly: true).plan else { throw ProviderError.unknownAccount }
        return plan
    }
    private func run(executable: String?, timeout: TimeInterval, environment: [String: String]?, accountOnly: Bool) throws -> (plan: String?, snapshot: UsageSnapshot?) {
        guard let executable = executable ?? Self.findCLI() else { throw ProviderError.cliMissing }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = ["app-server"]
        if let environment { process.environment = environment }
        let input = Pipe(); let output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ProviderError.launchFailed }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, min(timeout, 3600)) * 1_000_000_000)
        defer {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        func awaitReadable() throws {
            while true {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { throw ProviderError.timeout }
                let millis = Int32(min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max)))
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, millis)
                if ready > 0 { return }
                if ready == 0 { throw ProviderError.timeout }
                if errno != EINTR { throw ProviderError.serviceError }
            }
        }
        var accountChanged = false
        func request(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
            let message: [String: Any] = ["id": id, "method": method, "params": params]
            var bytes = try JSONSerialization.data(withJSONObject: message); bytes.append(10)
            do { try input.fileHandleForWriting.write(contentsOf: bytes) } catch { throw ProviderError.serviceError }
            var line = Data()
            while true {
                try awaitReadable()
                guard let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else {
                    throw ProviderError.serviceError
                }
                if byte[0] != 10 { line.append(byte); if line.count > 1_000_000 { throw ProviderError.invalidResponse }; continue }
                defer { line.removeAll(keepingCapacity: true) }
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw ProviderError.invalidResponse }
                if let method = obj["method"] as? String, method == "account/updated" { accountChanged = true }
                guard let responseID = obj["id"] as? Int, responseID == id else { continue }
                if obj["error"] != nil { throw ProviderError.serviceError }
                guard let result = obj["result"] as? [String: Any] else { throw ProviderError.invalidResponse }
                return result
            }
        }
        _ = try request(1, "initialize", ["clientInfo": ["name": "ai_usage_bar", "version": "0.1.0"]])
        let account = try request(2, "account/read", ["refreshToken": false])
        guard let accountInfo = account["account"] as? [String: Any] else { throw ProviderError.disconnected }
        try Self.validateAccount(type: accountInfo["type"] as? String, plan: accountInfo["planType"] as? String)
        guard let email = accountInfo["email"] as? String, !email.isEmpty else { throw ProviderError.unknownAccount }
        if accountOnly { return (accountInfo["planType"] as? String, nil) }
        let result = try request(3, "account/rateLimits/read", [:])
        let check = try request(4, "account/read", ["refreshToken": false])
        guard !accountChanged, let after = check["account"] as? [String: Any],
              after["email"] as? String == email,
              after["type"] as? String == accountInfo["type"] as? String,
              after["planType"] as? String == accountInfo["planType"] as? String else { throw ProviderError.unknownAccount }
        return (accountInfo["planType"] as? String, try UsageSnapshot.decode(JSONSerialization.data(withJSONObject: result)))
    }
}

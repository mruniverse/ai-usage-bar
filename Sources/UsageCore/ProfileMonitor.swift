import Foundation
import Darwin

public struct ProfileState {
    public var connection: ProfileConnection = .notChecked
    public var snapshot: UsageSnapshot?
    public var updatedAt: Date?
    public var checkedAt: Date?
    public var loading = false
    var backoff = RetryBackoff()
    var fingerprint = ""
    public var retryAt: Date? { backoff.nextRetry }
    public init() {}
}

/// Estado, cache e backoff independentes por perfil. Uma consulta de cada vez (todas as contas),
/// e cliques repetidos no mesmo perfil não iniciam nova consulta enquanto uma está em curso.
public final class ProfileMonitor {
    private let validator: ProfileValidator
    private let stateLock = NSLock()
    private let runLock = NSLock()
    private var states: [String: ProfileState] = [:]
    private var inFlight = Set<String>()
    private var cursor = 0

    public init(validator: ProfileValidator = ProfileValidator()) { self.validator = validator }

    public static func fingerprint(_ profile: Profile) -> String {
        [profile.provider.rawValue, profile.configDir, profile.executable ?? ""].joined(separator: "\u{1f}")
    }

    public func state(for id: String) -> ProfileState {
        stateLock.lock(); defer { stateLock.unlock() }
        return states[id] ?? ProfileState()
    }

    /// Trocar pasta, provedor ou executável descarta cache, backoff e dados do perfil.
    public func invalidateIfChanged(_ profile: Profile) {
        stateLock.lock(); defer { stateLock.unlock() }
        resetIfChanged(profile)
    }
    private func resetIfChanged(_ profile: Profile) {
        let print = Self.fingerprint(profile)
        if let current = states[profile.id], current.fingerprint != print { states[profile.id] = ProfileState(fingerprint: print) }
        else if states[profile.id] == nil { states[profile.id] = ProfileState(fingerprint: print) }
    }
    public func forget(id: String) { stateLock.lock(); states[id] = nil; stateLock.unlock() }

    @discardableResult
    public func refresh(_ profile: Profile, now: Date = Date()) -> ProfileState {
        _ = perform(profile, now: now)
        return state(for: profile.id)
    }

    /// Consulta os perfis visíveis, no máximo `maxPerCycle` por ciclo (com rodízio) e com pausa entre eles.
    @discardableResult
    public func refreshAll(_ profiles: [Profile], now: Date = Date(), maxPerCycle: Int = 8, stagger: TimeInterval = 1) -> Int {
        let visible = profiles.filter(\.visible)
        guard !visible.isEmpty, maxPerCycle > 0 else { return 0 }
        stateLock.lock(); let start = cursor % visible.count; stateLock.unlock()
        let ordered = Array(visible[start...] + visible[..<start]).prefix(maxPerCycle)
        var ran = 0
        for profile in ordered {
            if perform(profile, now: now) { ran += 1; if stagger > 0 { Thread.sleep(forTimeInterval: stagger) } }
        }
        stateLock.lock(); cursor += ordered.count; stateLock.unlock()
        return ran
    }

    /// Cartões do painel: perfis visíveis e conectados (ou ainda sendo verificados pela primeira vez).
    public func panelProfiles(_ profiles: [Profile]) -> [Profile] {
        profiles.filter { profile in
            guard profile.visible else { return false }
            let connection = state(for: profile.id).connection
            return connection.isConnected || connection == .notChecked
        }
    }

    private func perform(_ profile: Profile, now: Date) -> Bool {
        stateLock.lock()
        resetIfChanged(profile)
        var current = states[profile.id]!
        guard !inFlight.contains(profile.id), current.backoff.canRetry(at: now) else { stateLock.unlock(); return false }
        inFlight.insert(profile.id)
        // Sem reaproveitar dados entre consultas: a continuidade da conta não pode ser garantida.
        current.loading = true; current.snapshot = nil
        states[profile.id] = current
        stateLock.unlock()

        runLock.lock()
        var connection: ProfileConnection
        var snapshot: UsageSnapshot?
        switch profile.provider {
        case .codex: (connection, snapshot) = validator.queryCodex(profile)
        case .claude: (connection, snapshot) = validator.queryClaude(profile)
        }
        runLock.unlock()

        stateLock.lock(); defer { stateLock.unlock() }
        inFlight.remove(profile.id)
        guard var result = states[profile.id], result.fingerprint == Self.fingerprint(profile) else { return true }
        result.loading = false
        result.connection = connection
        result.checkedAt = now
        result.snapshot = snapshot
        if connection.isConnected {
            result.backoff.succeeded()
            result.updatedAt = now
        } else {
            result.backoff.failed(at: now)
            result.updatedAt = nil
        }
        states[profile.id] = result
        return true
    }
}

extension ProfileState {
    init(fingerprint: String) { self.init(); self.fingerprint = fingerprint }
}

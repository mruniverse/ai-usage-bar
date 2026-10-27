import SwiftUI
import AppKit
import UsageCore

@MainActor final class AppModel: ObservableObject {
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var states: [String: ProfileState] = [:]
    @Published private(set) var suggestions: [ProfileSuggestion] = []
    @Published private(set) var refreshing = false
    @Published var notice: String?
    private let store: ProfileStore
    private let monitor: ProfileMonitor
    private var timers: [Timer] = []

    init() {
        store = ProfileStore()
        monitor = ProfileMonitor()
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        do { try store.loadOrMigrate(defaultCodexHome: codexHome) }
        catch { notice = (error as? ProfileStoreError)?.message ?? "Não foi possível ler os perfis." }
        sync()
        refresh()
        timers.append(Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
    }

    var panelProfiles: [Profile] { monitor.panelProfiles(profiles) }
    func state(_ profile: Profile) -> ProfileState { states[profile.id] ?? ProfileState() }
    var lastUpdate: Date? { states.values.compactMap(\.updatedAt).max() }

    private func syncStates() { states = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, monitor.state(for: $0.id)) }) }
    private func sync() {
        profiles = store.profiles
        syncStates()
        refreshSuggestions()
    }
    func refreshSuggestions() { suggestions = ProfileDiscovery.suggestions(home: NSHomeDirectory(), existing: store.profiles) }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let list = profiles, monitor = monitor
        Task {
            _ = await Task.detached(priority: .utility) { monitor.refreshAll(list) }.value
            refreshing = false
            syncStates()
        }
    }
    private func validate(_ profile: Profile) {
        let monitor = monitor
        Task {
            _ = await Task.detached(priority: .utility) { monitor.refresh(profile) }.value
            syncStates()
        }
    }

    // MARK: ações da tela Contas

    @discardableResult
    func add(provider: ProviderKind, nickname: String, configDir: String, executable: String?) -> Bool {
        perform {
            let profile = try store.add(provider: provider, nickname: nickname, configDir: configDir, executable: executable)
            monitor.invalidateIfChanged(profile)
            sync(); validate(profile)
        }
    }
    func activate(_ suggestion: ProfileSuggestion, nickname: String) {
        add(provider: suggestion.provider, nickname: nickname, configDir: suggestion.configDir, executable: nil)
    }
    @discardableResult
    func rename(_ profile: Profile, to nickname: String) -> Bool { perform { try store.rename(id: profile.id, to: nickname); sync() } }
    func setVisible(_ profile: Profile, _ visible: Bool) { perform { try store.setVisible(id: profile.id, visible); sync() } }
    func remove(_ profile: Profile) { perform { try store.remove(id: profile.id); monitor.forget(id: profile.id); sync() } }
    func move(_ profile: Profile, by delta: Int) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        perform { try store.move(id: profile.id, to: index + delta); sync() }
    }
    func setExecutable(_ profile: Profile, _ path: String?) {
        perform {
            try store.setExecutable(id: profile.id, path)
            if let updated = store.profiles.first(where: { $0.id == profile.id }) { monitor.invalidateIfChanged(updated); sync(); validate(updated) }
        }
    }
    func copyLoginCommand(_ profile: Profile) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(LoginCommand.text(for: profile), forType: .string)
        notice = "Comando copiado. Cole no Terminal."
    }
    @discardableResult
    private func perform(_ action: () throws -> Void) -> Bool {
        do { try action(); notice = nil; return true }
        catch { notice = (error as? ProfileStoreError)?.message ?? "Não foi possível concluir a ação."; return false }
    }

    /// Seletor de pasta/arquivo do macOS. Mostra itens ocultos porque as pastas de perfil começam com ponto.
    static func choose(directory: Bool, startingAt: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: startingAt ?? NSHomeDirectory())
        panel.prompt = "Escolher"
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

@main struct AIUsageBarApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        MenuBarExtra("AI Usage Bar", systemImage: "chart.bar.fill") {
            PanelView(model: model)
        }.menuBarExtraStyle(.window)
    }
}

struct PanelView: View {
    @ObservedObject var model: AppModel
    @State private var showingSettings = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI Usage").font(.system(size: 21, weight: .bold, design: .rounded))
                    Text("Suas janelas de uso, em um lugar.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.refresh() } label: {
                    if model.refreshing {
                        ProgressView().controlSize(.small).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
                    }
                }
                .help(model.refreshing ? "Atualizando…" : "Atualizar agora")
                .accessibilityLabel(model.refreshing ? "Atualizando" : "Atualizar agora")
                .disabled(model.refreshing)
            }
            if showingSettings {
                AccountsView(model: model)
            } else {
                let shown = model.panelProfiles
                if shown.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nenhuma conta conectada.").font(.subheadline.weight(.medium))
                        Text("Abra Configurações → Contas para ativar um perfil e ver como conectá-lo.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Abrir Contas") { showingSettings = true }
                    }.cardStyle()
                }
                ForEach(shown) { profile in ProfileCard(profile: profile, state: model.state(profile), refreshing: model.refreshing) }
            }
            HStack {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    if let date = model.lastUpdate {
                        Text("\(context.date.timeIntervalSince(date) >= 900 ? "Desatualizado · " : "Atualizado · ")\(date.formatted(date: .omitted, time: .shortened))")
                    } else { Text("Sem leitura atual") }
                }
                Spacer()
                Button(showingSettings ? "Voltar" : "Configurações") {
                    showingSettings.toggle()
                    if showingSettings { model.refreshSuggestions() }
                }
                Button("Sair") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(18).frame(width: 360)
    }
}

/// Um cartão por perfil conectado, rotulado pelo apelido.
struct ProfileCard: View {
    let profile: Profile
    let state: ProfileState
    let refreshing: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(profile.nickname, systemImage: profile.provider == .claude ? "sparkles" : "terminal.fill").font(.headline)
                Spacer()
                if case .subscription(let plan?) = state.connection { Text(plan.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary) }
            }
            usageBody
            if profile.provider == .claude, state.snapshot != nil {
                Text("Consultado via Claude Code").font(.caption2).foregroundStyle(.secondary)
            }
        }.cardStyle()
    }
    @ViewBuilder var usageBody: some View {
        if let snapshot = state.snapshot {
            if snapshot.windows.isEmpty { Text("Limites indisponíveis para esta conta.").font(.caption).foregroundStyle(.secondary) }
            ForEach(snapshot.windows) { window in WindowView(window: window) }
            if snapshot.windows.count == 1 { Text("Leitura parcial: apenas uma janela informada.").font(.caption2).foregroundStyle(.secondary) }
        } else if refreshing || state.loading {
            HStack { ProgressView().controlSize(.small); Text("Consultando limites…").font(.caption) }
        } else {
            Text("Sem leitura atual.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct WindowView: View {
    let window: UsageWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(window.title).font(.subheadline.weight(.medium)); Spacer(); Text("\(window.usedPercent)% usado").font(.subheadline.monospacedDigit().weight(.semibold)) }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(LinearGradient(colors: [.cyan, .blue, .purple], startPoint: .leading, endPoint: .trailing)).frame(width: geo.size.width * CGFloat(window.usedPercent) / 100)
                }
            }.frame(height: 7).accessibilityElement().accessibilityLabel("\(window.title), \(window.usedPercent) por cento usado")
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if let reset = window.reset, let remaining = ResetCountdown.text(reset: reset, now: context.date) {
                    Text("Renova \(reset.formatted(date: .abbreviated, time: .shortened)) · faltam \(remaining)")
                        .font(.caption2).foregroundStyle(.secondary)
                } else { Text("Horário de renovação indisponível").font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }
}

extension View {
    func cardStyle() -> some View {
        padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(.primary.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.06)))
    }
}

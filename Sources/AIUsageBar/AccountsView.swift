import SwiftUI
import AppKit
import UsageCore

/// Configurações → Contas: ativar sugestões, adicionar manualmente, renomear, ocultar, reordenar, remover.
struct AccountsView: View {
    @ObservedObject var model: AppModel
    @State private var renaming: String?
    @State private var draftName = ""
    @State private var confirmRemoval: Profile?
    @State private var suggestionNames: [String: String] = [:]
    @State private var manualProvider: ProviderKind = .claude
    @State private var manualDir: String?
    @State private var manualExe: String?
    @State private var manualName = ""
    @State private var contentHeight: CGFloat = 0

    /// Até metade da altura útil da tela (menos cabeçalho e rodapé do painel); acima disso, rola.
    private var maxContentHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(240, screen * 0.5 - 130)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Contas").font(.headline)
                if let notice = model.notice {
                    Label(notice, systemImage: "info.circle").font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                if model.profiles.isEmpty {
                    Text("Nenhum perfil ativado. Ative uma sugestão abaixo ou adicione uma pasta manualmente.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(model.profiles.enumerated()), id: \.element.id) { index, profile in
                    row(profile, index: index)
                }
                if !model.suggestions.isEmpty { suggestionsSection }
                manualSection
            }.frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { geo in
                Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
            })
        }.frame(height: contentHeight > 0 ? min(contentHeight, maxContentHeight) : maxContentHeight)
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .confirmationDialog("Remover este perfil?", isPresented: Binding(get: { confirmRemoval != nil }, set: { if !$0 { confirmRemoval = nil } }), presenting: confirmRemoval) { profile in
            Button("Remover \(profile.nickname)", role: .destructive) { model.remove(profile) }
        } message: { _ in Text("Só o perfil é removido do app. A pasta de configuração e o login não são alterados.") }
    }

    private func row(_ profile: Profile, index: Int) -> some View {
        let state = model.state(profile)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: state.connection.isConnected ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .foregroundStyle(state.connection.isConnected ? Color.green : Color.orange)
                    .accessibilityLabel(state.connection.isConnected ? "Conectado" : "Atenção")
                if renaming == profile.id {
                    TextField("Apelido", text: $draftName).textFieldStyle(.roundedBorder)
                        .onSubmit { if model.rename(profile, to: draftName) { renaming = nil } }
                    Button("Salvar") { if model.rename(profile, to: draftName) { renaming = nil } }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.nickname).font(.subheadline.weight(.semibold))
                        Text("\(profile.provider.displayName) · \(profile.configDir)").font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                }
            }
            Text(profile.visible ? state.connection.message(for: profile.provider) : "Oculto: não é consultado nem aparece no painel.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !state.connection.isConnected && profile.visible && state.connection != .notChecked {
                Text(LoginCommand.text(for: profile)).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.06)))
            }
            HStack(spacing: 10) {
                Button { model.copyLoginCommand(profile) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copiar comando de login").accessibilityLabel("Copiar comando de login")
                Button { renaming = profile.id; draftName = profile.nickname } label: { Image(systemName: "pencil") }
                    .help("Renomear").accessibilityLabel("Renomear")
                Button { model.setVisible(profile, !profile.visible) } label: { Image(systemName: profile.visible ? "eye.slash" : "eye") }
                    .help(profile.visible ? "Ocultar" : "Mostrar").accessibilityLabel(profile.visible ? "Ocultar" : "Mostrar")
                Button { model.move(profile, by: -1) } label: { Image(systemName: "arrow.up") }
                    .disabled(index == 0).help("Subir").accessibilityLabel("Mover para cima")
                Button { model.move(profile, by: 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(index == model.profiles.count - 1).help("Descer").accessibilityLabel("Mover para baixo")
                Button { if let path = AppModel.choose(directory: false) { model.setExecutable(profile, path) } } label: { Image(systemName: "terminal") }
                    .help("Escolher executável do CLI").accessibilityLabel("Escolher executável")
                Spacer()
                Button(role: .destructive) { confirmRemoval = profile } label: { Image(systemName: "trash") }
                    .help("Remover perfil").accessibilityLabel("Remover perfil")
            }.buttonStyle(.borderless)
        }.cardStyle()
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sugestões encontradas").font(.subheadline.bold())
            Text("Nada é consultado antes de você ativar.").font(.caption2).foregroundStyle(.secondary)
            ForEach(model.suggestions) { suggestion in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(suggestion.provider.displayName) · \(suggestion.configDir)").font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    HStack {
                        TextField("Apelido", text: Binding(get: { suggestionNames[suggestion.id] ?? suggestion.suggestedNickname },
                                                         set: { suggestionNames[suggestion.id] = $0 })).textFieldStyle(.roundedBorder)
                        Button("Ativar") { model.activate(suggestion, nickname: suggestionNames[suggestion.id] ?? suggestion.suggestedNickname) }
                    }
                }
            }
        }.cardStyle()
    }

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Adicionar manualmente").font(.subheadline.bold())
            Picker("Provedor", selection: $manualProvider) {
                ForEach(ProviderKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }.pickerStyle(.segmented)
            HStack {
                Button("Escolher pasta…") { if let path = AppModel.choose(directory: true) { manualDir = path } }
                Text(manualDir ?? "nenhuma pasta").font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Button("Executável (opcional)…") { if let path = AppModel.choose(directory: false) { manualExe = path } }
                Text(manualExe ?? "automático").font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            HStack {
                TextField("Apelido", text: $manualName).textFieldStyle(.roundedBorder)
                Button("Adicionar") {
                    if let dir = manualDir, model.add(provider: manualProvider, nickname: manualName, configDir: dir, executable: manualExe) {
                        manualDir = nil; manualExe = nil; manualName = ""
                    }
                }.disabled(manualDir == nil)
            }
        }.cardStyle()
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

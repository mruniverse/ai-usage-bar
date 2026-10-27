# AI Usage Bar

Aplicativo nativo de barra de menus para limites de assinaturas Codex (ChatGPT) e Claude Code (claude.ai), organizado por **perfis**: um perfil é uma pasta de configuração de um CLI (`CODEX_HOME` / `CLAUDE_CONFIG_DIR`) com apelido. O painel mostra um cartão por perfil conectado. Só assinaturas são suportadas; API key e pagamento por uso são recusados com mensagem própria.

## Requisitos

- macOS 13 ou posterior (mínimo de compilação; ainda não testado em todas as versões).
- Xcode ou Command Line Tools com Swift compatível com Swift 5.9 ou posterior.
- Codex CLI recente que ofereça `codex app-server` e login ChatGPT de assinatura. No Terminal, execute `codex login`; o login e a renovação são responsabilidade do CLI.

## Compilar e abrir

No diretório do projeto:

```sh
./scripts/build-app.sh
open '.build/AI Usage Bar.app'
```

O app aparece como um ícone de gráfico na barra de menus; clique para abrir o painel. Para instalá-lo, copie o `.app` gerado para Aplicativos pelo Finder. O pacote local não é assinado para distribuição nem notarizado; outro Mac pode exigir liberação explícita no macOS. Ele não inicia automaticamente com a sessão. Para sair, use **Sair** no painel.

## Perfis (Configurações → Contas)

- Perfil = {apelido, provedor Claude|Codex, pasta de configuração, executável opcional, visível}. Fica em `~/Library/Application Support/AIUsageBar/profiles.json` (pasta 700, arquivo 600, escrita atômica) e **nunca** contém credenciais.
- No primeiro uso é criado o perfil **Codex** (pasta `CODEX_HOME` ou `~/.codex`). Se você removê-lo, ele não volta.
- **Sugestões:** o app lista pastas `~/.claude*` e `~/.codex*` (ignora backups, arquivos e links simbólicos) como sugestões **não ativadas**; nada é consultado antes de você dar um apelido e tocar em *Ativar*. A descoberta só olha nomes de pastas no home e não abre nem lê nada dentro delas.
- **Manual:** escolha o provedor, a pasta (seletor do macOS, que mostra itens ocultos) e, se quiser, o executável. O app valida na hora.
- Cada perfil pode ser renomeado, ocultado (oculto não é consultado), reordenado (setas para cima/baixo; não há arrastar) e removido. Remover só apaga o perfil do app, nunca a pasta nem o login. Duas entradas para a mesma pasta e provedor são recusadas.
- **Login:** para perfis desconectados o app mostra e copia o comando, por exemplo `CLAUDE_CONFIG_DIR='/Users/voce/.claude-kory' claude auth login` ou `CODEX_HOME='...' codex login`. O app não executa login nem escreve em credenciais.
- Cada perfil tem estado, cache e backoff próprios; as consultas rodam uma de cada vez (no máximo 8 perfis por ciclo, com pausa entre elas). O subprocesso de cada perfil recebe só a variável do próprio perfil: `CLAUDE_CONFIG_DIR` e `CODEX_HOME` herdados do ambiente são removidos.
- Estados distintos: pasta inválida, CLI ausente, deslogado, API key/plano gratuito/assinatura não confirmada (não suportado), assinatura OK e falha temporária (timeout, resposta inesperada, formato do `/usage` não reconhecido).
- Perfis ocultos, desconectados ou não suportados aparecem apenas em Configurações.

## Atualização e privacidade

O app consulta o Codex e o Claude (via `/usage`, ver "Como o Claude é lido") ao iniciar, a cada cinco minutos e ao clicar em atualizar, com timeout de 15 segundos (30 s para o `/usage` do Claude) e no máximo uma consulta simultânea. A leitura acima de 15 minutos é marcada como desatualizada. Para evitar misturar contas, a leitura anterior de cada perfil é descartada ao iniciar nova consulta daquele perfil; não há cache persistente de uso. Janelas e horários ausentes não são tratados como zero. A troca de conta durante uma consulta ainda não é detectada de forma garantida.

A consulta Codex usa o protocolo experimental de `codex app-server` por stdio, com `initialize`, `account/read` e `account/rateLimits/read`; o CLI gerencia autenticação. Somente tipos de assinatura ChatGPT reconhecidos são aceitos; planos desconhecidos são indeterminados e API key ou plano gratuito não são suportados. Perfis indisponíveis aparecem em Configurações, não no painel. O app não lê credenciais. Cada subprocesso herda o ambiente do usuário, exceto `CLAUDE_CONFIG_DIR`/`CODEX_HOME`, que vêm do perfil; o CLI pode fazer suas próprias conexões e gerenciar seu próprio armazenamento. Erros do CLI são exibidos sem detalhes potencialmente sensíveis. O app não depende do Hermes.

## Como o Claude é lido

Para cada perfil Claude o app faz duas consultas, uma de cada vez e com o ambiente do próprio perfil (`CLAUDE_CONFIG_DIR` apontando para a pasta do perfil; `CLAUDE_CONFIG_DIR`/`CODEX_HOME` herdados são removidos):

1. `claude auth status`: lê apenas `loggedIn`, `authMethod` e `subscriptionType`. Só `claude.ai` com plano Pro, Max, Team ou Enterprise conta como assinatura; chave de API e plano gratuito são "não suportado".
2. Só se for assinatura: `claude -p "/usage" --no-session-persistence`, executado em um diretório temporário vazio criado pelo app e removido depois (timeout de 30 s, com SIGKILL se o CLI não encerrar). O comando imprime texto e, nas observações feitas, não chama o modelo; a flag `--no-session-persistence` é obrigatória, pois sem ela o CLI grava um arquivo de sessão a cada chamada.

O app **não edita nenhum arquivo do Claude Code** (nem `settings.json`, nem status line) e **não lê tokens nem credenciais**; o login e a renovação continuam sendo do CLI. O cartão mostra as janelas **Sessão** (`Current session`), **Semanal** (`Current week (all models)`) e, se existirem, janelas extras `Semanal · <Modelo>` (`Current week (<Modelo>)`), cada uma com barra, percentual, horário de renovação e tempo restante, e o rótulo "Consultado via Claude Code". A atualização é a mesma do Codex: ao iniciar, a cada 5 minutos e pelo botão, com backoff por perfil após falhas (o botão manual não o contorna).

**Fragilidade:** `/usage` **não é uma interface documentada como estável**. O app interpreta o texto em inglês (`N% used · resets Mon D at H[:MM]am/pm (Fuso)`). Se o texto mudar, vier em outro idioma ou não tiver nenhuma janela reconhecida, o perfil aparece em Configurações como "formato não reconhecido" e nada é exibido; nunca se mostra 0%. Linhas desconhecidas são ignoradas; reset ilegível vira "horário indisponível"; o ano do reset é inferido (sempre no futuro).

**Não verificado:** só foi observado o plano `team`, em inglês, com este formato de texto. Outros planos, idiomas, versões do CLI e as linhas por modelo (Opus/Sonnet) e de uso extra não foram vistos em dados reais; o reconhecimento de login ausente/API key pelo texto do `/usage` também é suposição (o primeiro filtro é o `claude auth status`).

## Diagnóstico e testes

```sh
swift test
# Opcional: usa o login local e faz uma consulta real, sem imprimir dados de uso
AI_USAGE_LIVE_TEST=1 swift test
# Opcional: valida um perfil Claude real e consulta /usage (imprime só o estado e a contagem de janelas, não os dados)
AI_USAGE_LIVE_CLAUDE_DIR="$HOME/.claude-kory" swift test --filter testLiveClaude
```

O app procura `codex` e `claude` (quando o perfil não define executável) no PATH herdado e em `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` e `/usr/bin`. Apps iniciados pelo Finder podem receber um PATH diferente do Terminal; se seu CLI estiver em outro diretório, instale-o em um desses locais ou inicie o app a partir de um ambiente com PATH apropriado. O app informa ausência do CLI, login ausente, tipo de conta incompatível, timeout e falhas genéricas; 401, 403, 429 e erros de rede ainda não são diferenciados pelo adaptador. Após falhas (inclusive perfil deslogado), há backoff exponencial de 30 a 300 segundos **por perfil**, compartilhado pelas atualizações manual e automática; trocar a pasta ou o executável do perfil zera o backoff. Protocolos e formatos podem mudar em versões futuras do CLI.

Os testes automatizados usam executáveis falsos (scripts shell que imitam `claude auth status`, `claude -p /usage` e `codex app-server`) e diretórios temporários; nunca tocam o Application Support real. O parser do `/usage` é testado com o texto real observado e variações (hora sem minutos, 12am/12pm, virada de ano, fuso, linhas extras/desconhecidas, percentual inválido, texto vazio ou em outro idioma). A tela Contas e o painel (SwiftUI, seletor de pasta do macOS, copiar comando, cartão Claude com barras) compilam, mas **não foram validados visualmente nem por testes automatizados**.

O visual usa SwiftUI e controles nativos, com aparência de sistema em versões recentes; efeito Liquid Glass, acessibilidade, telas pequenas e instalação em outro Mac ainda exigem validação visual. Leia [o plano](docs/plan.md) para critérios e limitações do projeto. Não coloque credenciais, respostas privadas ou arquivos pessoais no repositório.

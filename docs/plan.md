# Plano inicial — AI Usage Bar

## Objetivo
Aplicativo nativo macOS na barra de menus para acompanhar limites das assinaturas Claude e Codex usando os logins locais de cada CLI, sem depender do Hermes. Interface clara, com barras de uso e materiais nativos Liquid Glass quando suportados.

## MVP
- Mostrar cartão por conta detectada e janelas de sessão e semanal, percentual usado e horário de reset quando fornecido.
- Atualizar em segundo plano em intervalo limitado e sob demanda; mostrar horário da última atualização.
- Tratar login ausente, acesso negado, limite HTTP 429, falha de rede e dados antigos de modo explícito; dados ausentes nunca significam 0%.
- Consultar credenciais locais sem exibir, registrar, copiar para o repositório ou transmitir a qualquer serviço fora dos endpoints legítimos do provedor.
- Login e renovação continuam responsabilidade das CLIs oficiais; não modificar armazenamento de autenticação sem necessidade comprovada.
- Instalação e diagnóstico reproduzíveis em outro Mac; código modular para futuros provedores.

## Fora do MVP
Outras IAs, login próprio, publicação, sincronização de credenciais, coleta de telemetria e alterações de conta.

### Notificações — fase futura, fora do MVP
- Usuário poderá escolher um ou vários patamares de percentual usado por assinatura e por janela, além de habilitar ou desabilitar alertas e alterar suas preferências.
- Solicitar permissão de notificações do macOS de forma explícita, respeitar negativa e permitir ajuste posterior; nunca implementar ou pedir permissão no MVP atual.
- Deduplicar cada alerta por assinatura, janela, reset e patamar; definir comportamento para alteração de limites, troca de conta e reinício do app.
- Dados desconhecidos, ausentes, atrasados ou de identidade não verificada não devem gerar falso alerta nem ser tratados como zero.
- Cobrir preferências, múltiplos patamares, permissão negada, limites parciais, atraso, troca de conta, reset e deduplicação com testes determinísticos e validação no macOS.

## Arquitetura proposta
Swift/SwiftUI e AppKit para menu bar, com adaptador por provedor e modelo comum de janelas. Usar controles e materiais nativos, com fallback quando Liquid Glass não estiver disponível. Resolver fontes de credencial conforme armazenamento real das CLIs, com menor privilégio; não depender de caminhos ou perfis pessoais fixos. Cada adaptador identifica a conta realmente consultada; não agregar percentuais de contas distintas.

## Segurança e limites
As integrações de quota podem ser não documentadas e mudar. Uma consulta Claude por cabeçalhos de mensagens (alternativa descartada) consumiria franquia; a fonte adotada, `/usage`, não chama o modelo (observado). Mesmo assim, manter intervalo conservador e backoff. Não duplicar chamadas simultâneas. Registrar apenas diagnósticos sem segredo. Distinguir dados em cache de dados atualizados. Recebimento de 429 sem cabeçalhos de uso não permite inferir percentual.

> **Aviso:** o comando `/usage` do Claude Code **não é uma interface documentada como estável**. O app depende do texto em inglês impresso por ele; qualquer mudança de formato, idioma ou versão pode quebrar a leitura. Nesse caso o app mostra "formato não reconhecido", nunca 0%, e os testes do parser são o contrato do formato esperado.

## Gates de implementação
1. Codex: validar protocolo app-server, autenticação delegada, versão e erros. Claude: validar fonte e método autorizado para login local, incluindo ausência e Keychain, com chamadas reais sem revelar segredos.
2. Revisão técnica e de produto do plano; registrar decisões e riscos.
3. Implementar modelo e adaptadores com testes determinísticos de parsing, janelas parciais, 429, login ausente e dados antigos.
4. Implementar a interface nativa com estados vazio, carregando, erro e atualizado.
5. Documentar pré-requisitos, build, instalação, login nas CLIs, intervalos, privacidade e troubleshooting; testar setup a partir do repositório.
6. Validar build, testes, abertura do aplicativo e leitura real dos provedores disponíveis. Não dizer que integração funciona quando login ou serviço impedir a validação.

## Critérios de aceite
- [ ] App aparece na barra de menus e abre um painel legível com barras por janela.
- [ ] Detecta logins locais Claude e Codex suportados e mostra dados reais quando disponíveis, sem vazar credenciais.
- [ ] Erros e dados desatualizados são explícitos; nunca criar 0% fictício.
- [ ] Atualização manual e periódica funciona sem bloquear a interface.
- [ ] README permite compilar e configurar em outro Mac sem depender de arquivos pessoais ou do Hermes.
- [ ] Testes automatizados e smoke test local documentados.

## Investigação local (27/10/2026)
- Xcode 26.5 e Swift 6.3.2 disponíveis; Claude Code 2.1.310 e Codex CLI 0.154.0 instalados. Isso não estabelece a versão mínima do produto.
- `codex login status` confirmou login ChatGPT. Uma consulta diretamente com a credencial local de `CODEX_HOME` (sem Hermes e sem imprimir segredos) ao endpoint de uso retornou HTTP 200, plano Plus e duas janelas. O endpoint é interno, sujeito a mudanças; fontes Keychain e renovação ainda precisam de investigação.
- `claude auth status` retornou `loggedIn: false`, apesar de existir arquivo de credenciais local. Sua existência isolada não prova uma sessão válida. Não foi verificado um login Claude local funcional nesta rodada; deixar o estado claramente desconectado e pedir login pelo CLI, sem usar silenciosamente contas do Hermes como substitutas.
- (Alternativa descartada pela decisão de 27/10/2026 abaixo.) A skill local do Hermes mostra que uma chamada de mensagens pode fornecer limites via cabeçalhos, mas consome franquia e pode não funcionar para todos os tokens ou planos. Confirmar autorização, compatibilidade e termos de uso antes de adotá-la; preferir fonte oficial quando disponível. HTTP 429 sem dados permanece indeterminado.
- A Apple informa que componentes nativos adotam o aspecto Liquid Glass nos sistemas recentes: https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass. Testar visual real e contraste; não presumir efeito aplicado a toda interface.

## Revisão independente e decisões incorporadas

Revisões técnica e de UX executadas em paralelo; achados incorporados abaixo. Pendências de Claude e de instalação externa permanecem gates, não conclusões de compatibilidade.

### Contrato e arquitetura
- Preferir `codex app-server` sobre leitura direta de tokens: o CLI cuida do login. Spike local executou `initialize` e `account/rateLimits/read` via stdio e recebeu dados reais. O protocolo é experimental; detectar versões incompatíveis e não executar métodos de mutação. A leitura direta de credenciais não é fallback silencioso.
- MVP cobre o login de assinatura ativo em cada CLI, não promete múltiplas contas por provedor. Se identidade ou continuidade não puder ser verificada, exibir conta não identificada e não persistir nem reutilizar cache; descartar respostas em andamento após troca detectada. Jamais misturar dados de contas.
- Claude: a fonte passou a ser `claude -p "/usage" --no-session-persistence` (ver decisão de 27/10/2026 abaixo). Falta ainda validação visual do cartão e de outros planos/idiomas antes de aceitar a integração; até lá a entrega é parcial, não cumprimento integral do MVP.
- Isolar adaptadores por processo/ator e fornecedor. Não renovar nem gravar tokens no app; autenticação e refresh pertencem às CLIs. Keychain bloqueado, negado, login ausente, API key e modo efêmero devem produzir estado claro, nunca outra conta silenciosamente.
- Evitar enviar segredos a domínios não autorizados, inclusive em redirecionamento; não colocar credenciais em argumentos, logs, cache, relatórios ou fixtures. Persistir apenas dados sanitizados, vinculados à identidade validada.
- Classificar janelas pela duração/metadados, não pela posição. Tratar campos ausentes separadamente. Uma falha em um provedor não bloqueia o outro.

### Atualização e estados
- Padrão inicial proposto: 5 minutos entre consultas bem-sucedidas, timeout 15 segundos, cache antigo após 15 minutos. Variáveis sujeitas a ajuste por limitações do provedor; nenhuma garantia de tempo real exato.
- Uma requisição por provedor simultaneamente; cliques repetidos não iniciam chamadas paralelas. Em 429, respeitar `Retry-After` quando presente e usar backoff exponencial com jitter; o botão manual não contorna o bloqueio. Aplicar backoff limitado também a falhas transitórias e respostas inválidas; não repetir agressivamente 401/403. Distinguir 401, 403, 429, rede, resposta inválida e login ausente.
- Na falha, conservar última leitura com seu timestamp, marcando-a antiga; não exibir reset passado como válido. Sem leitura anterior, exibir indisponível. Ao despertar o Mac, respeitar backoff e atualizar quando permitido.
- Interface em português, datas e horários no locale e fuso do sistema. Mostrar ícone neutro, cartões com barras, valores textuais e estado legível sem depender de cor; rotular carregando, parcial e desatualizado.

### Instalação, aparência e acessibilidade
- Primeiro marco: build local documentado a partir do repositório, sem assinatura paga ou publicação. Definir macOS mínimo antes de implementar; testar build e abertura nessa versão e em outro usuário limpo, registrando separadamente teste em outro Mac quando disponível. Documentar descoberta do CLI e mostrar estado claro para CLI ausente ou protocolo incompatível; distribuição de binários, assinatura Developer ID e notarização são fase separada.
- SwiftUI/AppKit com componentes de sistema e Liquid Glass quando houver suporte; fallback nativo. Validar claro/escuro, Reduzir Transparência e Aumentar Contraste. Com VoiceOver, cada controle tem nome e cada barra anuncia janela e valor ou indisponibilidade. Abrir, atualizar e fechar pelo teclado com foco visível; verificar que textos longos e ações não sejam cortados em telas pequenas. Não criar Glass artificial em todo o conteúdo.
- Iniciar o aplicativo automaticamente ao entrar no macOS fica fora do MVP até decisão explícita.

### Matriz de aceite e evidências
| Requisito | Verificação | Resultado |
|---|---|---|
| Painel com janelas e acessibilidade | Testes com fixtures e inspeção visual, teclado e VoiceOver | Pendente |
| Cada provedor independente e estados corretos | Testes com 401, 403, 429, ausência e parcial | Parcial: estados por perfil testados com CLIs falsos (ausente, deslogado, API key, free, timeout, inválido, formato do `/usage` não reconhecido); 401/403/429 não diferenciados |
| Cache e concorrência corretos | Simular troca de conta, sono, falha e cliques repetidos | Parcial: testados backoff por perfil, uma consulta por vez (inclusive `/usage`), cliques repetidos e descarte de leitura anterior; troca de conta durante consulta e sono não testados |
| Credenciais protegidas | Testes com tokens fictícios e inspeção de logs/cache/destinos | Pendente |
| Setup portátil | Build e instalação em outro ambiente sem Hermes | Pendente |
| Integração Codex | App-server local real | Spike validado; app não implementado |
| Integração Claude | Login local real e método autorizado | Parcial: assinatura `team` do perfil `~/.claude-kory` validada via `claude auth status`; `claude -p "/usage" --no-session-persistence` executado de verdade (teste opcional `AI_USAGE_LIVE_CLAUDE_DIR`: 2 janelas reconhecidas; nenhuma sessão `.jsonl` criada). Parser e cliente testados com executáveis falsos. Outros planos/idiomas e cartão na UI não verificados |

## Múltiplas contas e instalações (decisão de 27/10/2026)

Detecção 100% automática é insuficiente. Evidência local: um único binário `claude` e um único `codex` em `~/.local/bin`, mas diretórios de configuração separados (`~/.claude`, `~/.claude-kory`, `~/.codex`). As variantes (ex.: claude-kory, claude-thiago) provavelmente são aliases de shell que apontam `CLAUDE_CONFIG_DIR`/`CODEX_HOME` para outro diretório; um app iniciado pelo Finder não enxerga aliases. Logo, a unidade configurável é o **perfil**, não o binário.

### Modelo de perfil
Perfil = {id estável, apelido definido pelo usuário, provedor (Claude|Codex), diretório de configuração (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`), caminho opcional do executável, visível no painel (sim/não)}. Guardar somente esses metadados, nunca credenciais, em `~/Library/Application Support/AIUsageBar/profiles.json` (permissão 600). Cada perfil tem cache, backoff e estado independentes; nunca agregar perfis.

### Fluxo intuitivo
1. **Primeira abertura / Configurações → Contas:** o app sugere perfis encontrados (padrões `~/.claude*`, `~/.codex*`, filtrando backups e arquivos que não sejam diretório de configuração) como **sugestões não ativadas**; o usuário marca quais usar e dá o apelido. Nada é consultado antes da confirmação.
2. **Adicionar manualmente:** escolher provedor, selecionar a pasta (seletor do macOS) e opcionalmente o executável. Validar na hora: CLI presente, logado, assinatura (não API key). Mostrar o resultado em linguagem simples ("Conectado como assinatura ChatGPT", "Faça login: execute X no Terminal com este perfil").
3. **Mostrar o comando de login correto por perfil** (ex.: `CLAUDE_CONFIG_DIR=<pasta> claude auth login`), com botão copiar; o app não executa login nem escreve em credenciais.
4. **Painel:** um cartão por perfil habilitado e conectado, rotulado pelo apelido; ordem arrastável; ocultar/renomear/remover perfil em um clique. Perfis duplicados (mesma pasta ou mesma identidade) são sinalizados, não consultados duas vezes.
5. Sem nenhum perfil conectado: estado vazio que leva a Contas.

### Regras e riscos
- Identidade: só exibir e-mail/ID se o CLI a fornecer; senão "conta não identificada". Trocar o login dentro de uma pasta invalida o cache daquele perfil.
- Cada consulta roda com o ambiente do próprio perfil (variável de configuração injetada no subprocesso), sem herdar a do perfil vizinho; testar isolamento com dois perfis fictícios.
- Limite de perfis consultados por ciclo e intervalo escalonado, para não gerar rajada de chamadas.
- Descoberta nunca lê conteúdo de arquivos de credencial; apenas existência e nome de diretório.
- Migração: o comportamento atual (um Codex padrão) vira o perfil "Codex" criado automaticamente na primeira execução, editável.

### Aceite
- [x] Dois perfis fictícios com pastas distintas mostram dados sem se misturar. *Testado (`swift test`, executáveis falsos): dois perfis Codex com usos 20% e 70%; dois perfis Claude com leituras de `/usage` separadas; subprocesso recebe só a variável do próprio perfil (`CLAUDE_CONFIG_DIR`/`CODEX_HOME` do vizinho removidos).*
- [ ] Adicionar, renomear, ocultar, reordenar e remover perfil funciona sem editar arquivos. *Parcial: as operações do `ProfileStore` estão testadas (renomear, ocultar, reordenar, remover, duplicado, apelido inválido, remover não toca a pasta). A tela Contas (botões, seletor NSOpenPanel, copiar comando) compila mas não foi exercitada nem testada; reordenar é por setas, não por arrastar.*
- [x] Pasta inválida, CLI ausente, deslogado e API key geram mensagens distintas. *Testado para Claude e Codex: cada estado é produzido por executável falso e todas as mensagens são distintas e não vazias. A exibição dessas mensagens na UI não foi testada.*
- [x] `profiles.json` não contém segredos (teste automatizado) e tem permissão 600; diretório 700, escrita atômica sem sobras, link simbólico recusado.
- [ ] Usuário consegue conectar um segundo perfil em menos de 1 minuto sem ler documentação (teste de uso). *Não realizado.*

### Estado da implementação de perfis (testado vs. não testado)
- Testado automaticamente: modelo e persistência; normalização de caminho; sugestões `~/.claude*`/`~/.codex*` (ignora backups, arquivos, links simbólicos; não lê credenciais); validação Claude (`claude auth status`: assinatura team/max, deslogado, API key, plano gratuito, assinatura não confirmada, saída inválida, timeout com SIGKILL, CLI ausente, pasta inválida) e Codex (assinatura, deslogado, API key, plano gratuito, timeout, CLI ausente, pasta inválida); backoff e estado por perfil; uma consulta por vez e sem duplicar consulta do mesmo perfil; migração do perfil "Codex" apenas no primeiro uso; leitura Claude por `/usage`: parser (texto real observado, hora sem minutos, 12am/12pm, virada de ano, fuso, janelas extras por modelo, linha desconhecida, percentual inválido, texto vazio/outro idioma → formato não reconhecido), cliente com executável falso (argumentos incluem `--no-session-persistence`, cwd = diretório temporário removido depois, ambiente sem variáveis do vizinho, timeout que ignora SIGTERM morto por SIGKILL, stderr nunca interpretado, saída com código ≠ 0), isolamento entre dois perfis, `/usage` só executado para assinatura validada, backoff por perfil. Prova de mutação: removida a flag `--no-session-persistence` e aceito percentual inválido como 0; os testes falharam nos dois casos.
- Verificado manualmente com o login real: `claude auth status` do perfil `~/.claude-kory` foi classificado como assinatura `team` (teste opcional `AI_USAGE_LIVE_CLAUDE_DIR`). Isso comprova a identificação de assinatura. O `/usage` real do perfil também foi executado uma vez (2 janelas reconhecidas, sem criar arquivo de sessão); só foi observado o plano `team` em inglês.
- Não testado: interface SwiftUI de Contas e painel, inclusive o cartão Claude com barras, horário, tempo restante e rótulo "Consultado via Claude Code" (apenas compila; o app não foi aberto para inspeção visual), seletor de pasta do macOS, cópia para a área de transferência, comportamento do popover com o NSOpenPanel, `/usage` em outros planos, idiomas e versões do CLI, linhas por modelo (Opus/Sonnet) e de uso extra em dados reais, textos reais do `/usage` para login ausente/API key (a classificação por texto é suposição), consulta Codex com um segundo login real.
- Não implementado: arrastar para reordenar; sinalizar perfis distintos com a mesma identidade (só a mesma pasta+provedor é detectada); escalonamento fino além do limite de 8 perfis por ciclo e pausa de 1 s.

## Fonte de dados do Claude (decisão de 27/10/2026)

- **Decisão:** o app obtém os limites Claude executando `claude -p "/usage" --no-session-persistence` com `CLAUDE_CONFIG_DIR` do perfil, em um diretório temporário vazio criado e removido pelo app. O app **não edita nenhum arquivo do Claude Code** (nem `settings.json`/status line) e **não lê tokens nem credenciais**.
- **Fato verificado (plano team):** o comando imprime texto e sai com sucesso, sem chamada ao modelo (transcript sem mensagens do assistant, zero tokens). Sem `--no-session-persistence` ele cria um `.jsonl` em `projects/` a cada chamada, por isso a flag é obrigatória. Saída observada: linha sobre a assinatura, `Current session: N% used · resets Mon D at H[:MM]am/pm (Fuso)` e `Current week (all models): N% used · resets ...`.
- **Substitui** a captura por status line (script Python, arquivo `claude-status/<chave>.json`, instruções manuais), removida do repositório: ela dependia de configuração manual no `settings.json` e nunca teve dados reais verificados.
- **Contrato do parser:** janelas `Current session` → Sessão, `Current week (all models)` → Semanal, `Current week (<Modelo>)` → janela extra rotulada; percentual inteiro 0–100 (fora da faixa ou não numérico = formato não reconhecido); reset no fuso informado, ano inferido sempre no futuro (passado há mais de 1 dia → ano seguinte); reset ilegível = janela sem reset; linhas desconhecidas ignoradas; nenhuma janela reconhecida (inclusive outro idioma) = erro, nunca 0%.
- **Riscos aceitos:** `/usage` não é interface documentada como estável (ver aviso em Segurança e limites); só `team` em inglês foi observado.
- **Gate:** antes de considerar o Claude aceito, observar `/usage` em outro plano e verificar o cartão visualmente. Itens da matriz só ficam marcados quando testados.

## Decisões pendentes de investigação
- Fontes exatas de login das versões atuais das CLIs, incluindo Keychain, ambiente, múltiplas contas e observação de renovação realizada pelas CLIs, sem refresh pelo app.
- Estabilidade do `/usage` entre versões do Claude Code, planos e idiomas (não documentado como estável); reset em HTTP 429 não se aplica à fonte atual.
- Versão mínima do macOS e estratégia Liquid Glass compatível com SDK instalado.
- Revisão final dos ajustes antes de congelar o plano; as revisões técnica e de UX/produto iniciais foram realizadas.

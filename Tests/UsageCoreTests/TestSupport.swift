import Foundation
@testable import UsageCore

/// Diretório temporário isolado; nunca toca o Application Support real.
final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("aiusagebar-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    var path: String { url.path }

    @discardableResult
    func makeDir(_ relative: String) throws -> String {
        let dir = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
    @discardableResult
    func writeFile(_ relative: String, _ text: String, mode: Int = 0o644) throws -> String {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        return file.path
    }
    @discardableResult
    func writeScript(_ relative: String, _ body: String) throws -> String {
        try writeFile(relative, body, mode: 0o700)
    }
}

func posixMode(_ path: String) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber).intValue & 0o7777
}

/// Texto real observado de `claude -p "/usage"` (plano team), usado como padrão do executável falso.
let realUsageSample = """
You are currently using your subscription to power your Claude Code usage

Current session: 42% used · resets Oct 27 at 7:10pm (America/Sao_Paulo)
Current week (all models): 28% used · resets Nov 2 at 5pm (America/Sao_Paulo)
"""

/// Ramo `-p /usage` do `claude` falso: a saída vem de `$CLAUDE_CONFIG_DIR/fake-usage` (ou do texto real observado) e o modo
/// de `fake-usage-mode` (hang|stderr|stderrmix|exit1). Grava argumentos, cwd, pid e ambiente visto, para os testes provarem
/// que `--no-session-persistence` vai junto, que o cwd é o diretório temporário e que nada do vizinho vaza.
let fakeClaudeUsageBranch = #"""
#!/bin/sh
if [ "$1" = "-p" ]; then
  d="$CLAUDE_CONFIG_DIR"
  echo x >> "$d/usage-calls"
  printf '%s' "$*" > "$d/usage-args"
  pwd -P > "$d/usage-cwd"
  printf '%s' "$CODEX_HOME" > "$d/usage-seen-codex-home"
  printf '%s' "$CLAUDE_CONFIG_DIR" > "$d/usage-seen-claude-dir"
  printf '%s' "$$" > "$d/usage-pid"
  mode=$(cat "$d/fake-usage-mode" 2>/dev/null)
  out() { if [ -f "$d/fake-usage" ]; then cat "$d/fake-usage"; else printf '%s\n' 'You are currently using your subscription to power your Claude Code usage' '' 'Current session: 42% used · resets Oct 27 at 7:10pm (America/Sao_Paulo)' 'Current week (all models): 28% used · resets Nov 2 at 5pm (America/Sao_Paulo)'; fi; }
  case "$mode" in
    hang)      trap '' TERM; while :; do sleep 1; done ;;
    stderr)    printf 'Current session: 99%% used
' >&2; exit 0 ;;
    stderrmix) printf 'Current session: 99%% used
' >&2; out; exit 0 ;;
    exit1)     out; exit 1 ;;
    *)         out; exit 0 ;;
  esac
fi

"""#

/// Imita `claude auth status` (e, via `fakeClaudeUsageBranch`, `claude -p /usage`): o estado vem de `$CLAUDE_CONFIG_DIR/fake-state`.
/// Também grava o que viu no ambiente, para provar isolamento entre perfis.
let fakeClaudeScript = fakeClaudeUsageBranch + """
[ "$1" = auth ] && [ "$2" = status ] || exit 64
printf '%s' "$CODEX_HOME" > "$CLAUDE_CONFIG_DIR/seen-codex-home" 2>/dev/null
printf '%s' "$CLAUDE_CONFIG_DIR" > "$CLAUDE_CONFIG_DIR/seen-claude-dir" 2>/dev/null
state=$(cat "$CLAUDE_CONFIG_DIR/fake-state" 2>/dev/null)
case "$state" in
  team)    printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"team"}' ;;
  max)     printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}' ;;
  free)    printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"free"}' ;;
  notype)  printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai"}' ;;
  apikey)  printf '%s\\n' '{"loggedIn":true,"authMethod":"api_key"}' ;;
  loggedout) printf '%s\\n' '{"loggedIn":false}'; exit 1 ;;
  garbage) printf '%s\\n' 'not json at all' ;;
  hang)    trap '' TERM; sleep 5 & wait ;;
  *)       printf '%s\\n' '{"loggedIn":false}' ;;
esac
"""

/// Imita `codex app-server`: conta vem de `$CODEX_HOME/fake-account` (plus|apikey|free|none|a|b).
let fakeCodexScript = """
#!/bin/sh
printf '%s' "$CLAUDE_CONFIG_DIR" > "$CODEX_HOME/seen-claude-dir" 2>/dev/null
printf '%s' "$CODEX_HOME" > "$CODEX_HOME/seen-codex-home" 2>/dev/null
acct=$(cat "$CODEX_HOME/fake-account" 2>/dev/null)
read x; printf '%s\\n' '{"id":1,"result":{}}'
read x
case "$acct" in
  none)   printf '%s\\n' '{"id":2,"result":{"account":null}}'; exit 0 ;;
  apikey) printf '%s\\n' '{"id":2,"result":{"account":{"type":"apiKey"}}}'; exit 0 ;;
  free)   printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt","planType":"free","email":"x@example.invalid"}}}'; exit 0 ;;
  hang)   sleep 5; exit 0 ;;
  b)      email=b@example.invalid; used=70 ;;
  *)      email=a@example.invalid; used=20 ;;
esac
printf '{"id":2,"result":{"account":{"type":"chatgpt","planType":"plus","email":"%s"}}}\\n' "$email"
read x; printf '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":%s,"windowDurationMins":300},"planType":"plus"}}}\\n' "$used"
read x; printf '{"id":4,"result":{"account":{"type":"chatgpt","planType":"plus","email":"%s"}}}\\n' "$email"
"""

#!/usr/bin/env bash
set -euo pipefail

CODEX_APP="${CODEX_APP:-/Applications/Codex.app}"
SWITCHER_APP="${SWITCHER_APP:-$HOME/Applications/Codex 模型切换器.app}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
SWITCHER_SCRIPT="$SWITCHER_APP/Contents/Resources/provider-safe-guard.mjs"

state_dbs=(
  "$CODEX_HOME/state_5.sqlite"
  "$CODEX_HOME/sqlite/state_5.sqlite"
  "$CODEX_HOME/state/state_5.sqlite"
)

print_section() {
  printf '\n== %s ==\n' "$1"
}

sqlite_count() {
  /usr/bin/sqlite3 "$1" "select count(*) from threads;" 2>/dev/null || printf '0'
}

print_db_summary() {
  print_section "Codex session indexes"
  local found=0
  for db in "${state_dbs[@]}"; do
    if [[ ! -f "$db" ]]; then
      continue
    fi
    found=1
    printf '%s\n' "$db"
    /usr/bin/sqlite3 "$db" "select model_provider, model, count(*) from threads group by 1,2 order by 3 desc;" || true
  done
  if [[ "$found" == "0" ]]; then
    printf 'No Codex state database found. Open Codex and create a conversation first.\n'
  fi
}

print_section "Codex.app signature"
if [[ -d "$CODEX_APP" ]]; then
  /usr/bin/codesign --verify --deep --strict "$CODEX_APP"
  /usr/sbin/spctl -a -vv "$CODEX_APP" 2>&1 || true
else
  printf 'Missing: %s\n' "$CODEX_APP"
fi

print_section "Switcher app"
if [[ -d "$SWITCHER_APP" ]]; then
  /usr/bin/codesign --verify --deep --strict "$SWITCHER_APP"
  printf 'Switcher app: present\n'
else
  printf 'Missing: %s\n' "$SWITCHER_APP"
fi

print_section "DeepSeek key"
key_path="$CODEX_HOME/codex-deepseek-bridge/deepseek-key"
if [[ -s "$key_path" ]]; then
  perms="$(/bin/ls -l "$key_path" | awk '{print $1}')"
  bytes="$(/usr/bin/wc -c < "$key_path" | tr -d ' ')"
  printf 'DeepSeek key: present (%s bytes, %s)\n' "$bytes" "$perms"
else
  printf 'DeepSeek key: missing or empty\n'
fi

print_section "Initial backup"
manifest="$CODEX_HOME/codex-model-switcher/initial-backup/manifest.json"
if [[ -f "$manifest" ]]; then
  rows="$(/usr/bin/grep -c '"dbPath"' "$manifest" || true)"
  printf 'Initial backup: present (%s thread index rows)\n' "$rows"
else
  printf 'Initial backup: missing. Open the switcher app once to create it.\n'
fi

print_db_summary

if [[ "${1:-}" == "--roundtrip-index" ]]; then
  print_section "Roundtrip index test"
  if [[ ! -f "$SWITCHER_SCRIPT" ]]; then
    printf 'Missing provider-safe-guard.mjs in switcher app.\n' >&2
    exit 1
  fi

  primary_db="$CODEX_HOME/state_5.sqlite"
  if [[ ! -f "$primary_db" ]]; then
    printf 'Missing primary Codex state database: %s\n' "$primary_db" >&2
    exit 1
  fi

  before="$(sqlite_count "$primary_db")"
  /usr/bin/env node "$SWITCHER_SCRIPT" deepseek
  after_deepseek="$(sqlite_count "$primary_db")"
  /usr/bin/env node "$SWITCHER_SCRIPT" gpt
  after_gpt="$(sqlite_count "$primary_db")"

  printf 'primary count before: %s\n' "$before"
  printf 'after DeepSeek:       %s\n' "$after_deepseek"
  printf 'after GPT:            %s\n' "$after_gpt"

  if [[ "$before" != "$after_deepseek" || "$before" != "$after_gpt" ]]; then
    printf 'Thread count changed during roundtrip.\n' >&2
    exit 1
  fi

  print_db_summary
fi


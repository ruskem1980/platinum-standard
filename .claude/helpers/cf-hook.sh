#!/bin/bash
# cf-hook.sh — Быстрый executor для claude-flow хуков
# Приоритеты: unix socket relay (~5ms) → npx fallback (~2s)
#
# Использование: bash cf-hook.sh hooks post-edit --file "path" --success true

SOCKET="/tmp/claude-flow-hook-relay.sock"
LOG="/tmp/claude-flow-hooks.log"

# Логируем вызов
echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] HOOK: $*" >> "$LOG"

# Метод 1: Unix socket relay (быстро, ~5-50ms)
if [ -S "$SOCKET" ]; then
  # Собираем JSON массив из аргументов
  json_args="["
  first=true
  for arg in "$@"; do
    if [ "$first" = true ]; then first=false; else json_args+=","; fi
    # Экранируем кавычки и спецсимволы
    escaped=$(printf '%s' "$arg" | sed 's/\\/\\\\/g; s/"/\\"/g')
    json_args+="\"$escaped\""
  done
  json_args+="]"

  response=$(curl -s --max-time 3 --unix-socket "$SOCKET" \
    -X POST -H "Content-Type: application/json" \
    -d "{\"args\":$json_args}" \
    http://localhost/hook 2>>"$LOG")
  exit_code=$?

  if [ $exit_code -eq 0 ]; then
    echo "$response"
    exit 0
  fi

  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] RELAY UNAVAILABLE (exit=$exit_code), fallback to npx" >> "$LOG"
fi

# Метод 2: npx fallback (медленно, ~2s)
npx @claude-flow/cli@latest "$@" 2>>"$LOG"

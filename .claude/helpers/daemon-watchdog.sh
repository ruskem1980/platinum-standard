#!/bin/bash
# daemon-watchdog.sh — Проверка здоровья демона + очистка stale PID + управление relay
#
# Использование:
#   bash daemon-watchdog.sh check     — проверить и почистить stale state
#   bash daemon-watchdog.sh start     — запустить relay + почистить stale state
#   bash daemon-watchdog.sh stop      — остановить relay
#   bash daemon-watchdog.sh status    — показать состояние

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG="/tmp/claude-flow-hooks.log"

# Файлы состояния
RELAY_PID_FILE="/tmp/claude-flow-hook-relay.pid"
RELAY_SOCKET="/tmp/claude-flow-hook-relay.sock"

# Автоматический поиск daemon-state.json файлов
find_daemon_states() {
  find "$PROJECT_ROOT" -name "daemon-state.json" -path "*/.claude-flow/*" -maxdepth 5 2>/dev/null
}

# Автоматический поиск daemon.pid файлов
find_pid_files() {
  find "$PROJECT_ROOT" -name "daemon.pid" -path "*/.claude-flow/*" -maxdepth 5 2>/dev/null
}

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [watchdog] $1" >> "$LOG"
  echo "$1"
}

# Проверяем жив ли процесс по PID
is_alive() {
  local pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Очистка stale PID файлов + убийство orphan процессов
cleanup_stale_pids() {
  local fixed=0

  # PID файлы
  while IFS= read -r pid_file; do
    if [ -f "$pid_file" ]; then
      local pid=$(cat "$pid_file" 2>/dev/null)
      if ! is_alive "$pid"; then
        log "Stale PID обнаружен: $pid_file (PID $pid мёртв) — удаляю"
        rm -f "$pid_file"
        ((fixed++))
      fi
    fi
  done < <(find_pid_files)

  # Исправляем daemon-state.json: если running=true но PID мёртв — ставим false
  while IFS= read -r state_file; do
    if [ -f "$state_file" ]; then
      local running=$(python3 -c "import json; print(json.load(open('$state_file')).get('running', False))" 2>/dev/null)
      if [ "$running" = "True" ]; then
        local dir=$(dirname "$state_file")
        local pid_file="$dir/daemon.pid"
        local pid=$(cat "$pid_file" 2>/dev/null)
        if ! is_alive "$pid"; then
          log "Zombie state обнаружен: $state_file (running=true, PID мёртв) — исправляю"
          python3 -c "
import json
with open('$state_file', 'r') as f:
    data = json.load(f)
data['running'] = False
data['startedAt'] = None
data['savedAt'] = None
with open('$state_file', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null
          ((fixed++))
        fi
      fi
    fi
  done < <(find_daemon_states)

  # Убийство orphan daemon процессов (без PID файлов)
  kill_orphan_processes

  if [ $fixed -gt 0 ]; then
    log "Исправлено $fixed stale записей"
  else
    log "Stale state не обнаружен"
  fi
}

# Поиск и убийство orphan claude-flow процессов (демоны без PID файлов)
kill_orphan_processes() {
  # Собираем известные PID из файлов
  local known_pids=""
  if [ -f "$RELAY_PID_FILE" ]; then
    known_pids="$(cat "$RELAY_PID_FILE" 2>/dev/null)"
  fi
  while IFS= read -r pid_file; do
    if [ -f "$pid_file" ]; then
      local p=$(cat "$pid_file" 2>/dev/null)
      [ -n "$p" ] && known_pids="$known_pids $p"
    fi
  done < <(find_pid_files)

  # Ищем daemon процессы claude-flow
  local orphan_pids=$(pgrep -f "claude-flow.*daemon" 2>/dev/null)
  if [ -z "$orphan_pids" ]; then
    return
  fi

  for pid in $orphan_pids; do
    local is_known=false
    for kp in $known_pids; do
      [ "$pid" = "$kp" ] && is_known=true && break
    done

    if [ "$is_known" = false ]; then
      log "Orphan daemon PID $pid обнаружен — убиваю"
      kill "$pid" 2>/dev/null
      sleep 0.5
      if is_alive "$pid"; then
        kill -9 "$pid" 2>/dev/null
      fi
    fi
  done

  # Убийство дубликатов MCP серверов (оставляем только самый новый)
  local mcp_pids=$(pgrep -f "@claude-flow/cli.*mcp start" 2>/dev/null | sort -n)
  local mcp_count=$(echo "$mcp_pids" | grep -c .)
  if [ "$mcp_count" -gt 2 ]; then
    # Оставляем последние 2 (основной + bin), убиваем остальные
    local to_keep=$(echo "$mcp_pids" | tail -2)
    for pid in $mcp_pids; do
      if ! echo "$to_keep" | grep -q "^${pid}$"; then
        log "Дубликат MCP PID $pid — убиваю"
        kill "$pid" 2>/dev/null
      fi
    done
  fi
}

# Запуск hook relay
start_relay() {
  # Проверяем через socket (надёжнее чем PID файл)
  if [ -S "$RELAY_SOCKET" ]; then
    local health=$(curl -s --max-time 1 --unix-socket "$RELAY_SOCKET" http://localhost/health 2>/dev/null)
    if echo "$health" | grep -q '"ok":true'; then
      log "Hook relay уже запущен и отвечает"
      return 0
    else
      log "Socket есть, но relay не отвечает — перезапуск"
      rm -f "$RELAY_SOCKET"
    fi
  fi

  # Проверяем PID файл
  if [ -f "$RELAY_PID_FILE" ]; then
    local pid=$(cat "$RELAY_PID_FILE" 2>/dev/null)
    if is_alive "$pid"; then
      # PID жив но socket нет — ждём ещё немного
      for i in {1..10}; do
        if [ -S "$RELAY_SOCKET" ]; then
          log "Hook relay уже запущен (PID: $pid)"
          return 0
        fi
        sleep 0.1
      done
      log "PID $pid жив, но socket не появился — убиваем"
      kill "$pid" 2>/dev/null
      sleep 0.5
    fi
    rm -f "$RELAY_PID_FILE" "$RELAY_SOCKET"
  fi

  # Удаляем stale lock если есть
  local LOCK="/tmp/claude-flow-hook-relay.lock"
  if [ -f "$LOCK" ]; then
    local lock_pid=$(cat "$LOCK" 2>/dev/null)
    if ! is_alive "$lock_pid"; then
      rm -f "$LOCK"
    fi
  fi

  log "Запускаю hook relay v2..."
  nohup node "$SCRIPT_DIR/hook-relay.mjs" >> "$LOG" 2>&1 &
  local relay_pid=$!

  # Ждём запуска сокета (до 3 секунд)
  for i in {1..30}; do
    if [ -S "$RELAY_SOCKET" ]; then
      log "Hook relay запущен (PID: $relay_pid, socket: $RELAY_SOCKET)"
      return 0
    fi
    sleep 0.1
  done

  log "ОШИБКА: Hook relay не стартовал за 3 секунды"
  return 1
}

# Остановка hook relay
stop_relay() {
  if [ -f "$RELAY_PID_FILE" ]; then
    local pid=$(cat "$RELAY_PID_FILE" 2>/dev/null)
    if is_alive "$pid"; then
      log "Останавливаю hook relay (PID: $pid)..."
      kill "$pid" 2>/dev/null
      sleep 1
      if is_alive "$pid"; then
        kill -9 "$pid" 2>/dev/null
      fi
      log "Hook relay остановлен"
    fi
    rm -f "$RELAY_PID_FILE"
  fi
  rm -f "$RELAY_SOCKET"
}

# Показать статус
show_status() {
  echo "=== Claude Flow Watchdog Status ==="
  echo ""

  # Relay
  if [ -f "$RELAY_PID_FILE" ] && is_alive "$(cat "$RELAY_PID_FILE" 2>/dev/null)"; then
    echo "  Hook Relay:  RUNNING (PID: $(cat "$RELAY_PID_FILE"))"
  else
    echo "  Hook Relay:  STOPPED"
  fi
  echo ""

  # Daemon states
  while IFS= read -r state_file; do
    local name=$(echo "$state_file" | sed "s|$PROJECT_ROOT/||")
    if [ -f "$state_file" ]; then
      local running=$(python3 -c "import json; print(json.load(open('$state_file')).get('running', False))" 2>/dev/null)
      local started=$(python3 -c "import json; print(json.load(open('$state_file')).get('startedAt', 'never'))" 2>/dev/null)
      echo "  $name"
      echo "    running: $running, started: $started"
    fi
  done < <(find_daemon_states)
  echo ""

  # PID files
  while IFS= read -r pid_file; do
    local name=$(echo "$pid_file" | sed "s|$PROJECT_ROOT/||")
    if [ -f "$pid_file" ]; then
      local pid=$(cat "$pid_file" 2>/dev/null)
      if is_alive "$pid"; then
        echo "  $name: PID $pid (alive)"
      else
        echo "  $name: PID $pid (STALE!)"
      fi
    fi
  done < <(find_pid_files)
  echo ""

  # Лог размер
  if [ -f "$LOG" ]; then
    local size=$(du -h "$LOG" | cut -f1)
    local lines=$(wc -l < "$LOG" | tr -d ' ')
    echo "  Hook log: $LOG ($size, $lines lines)"
  fi

  echo "==================================="
}

# Обработка команд
case "${1:-check}" in
  "check")
    cleanup_stale_pids
    ;;
  "start")
    cleanup_stale_pids
    start_relay
    ;;
  "stop")
    stop_relay
    ;;
  "restart")
    stop_relay
    sleep 1
    cleanup_stale_pids
    start_relay
    ;;
  "status")
    show_status
    ;;
  "help"|"-h"|"--help")
    echo "daemon-watchdog.sh — Управление здоровьем демона и hook relay"
    echo ""
    echo "Команды:"
    echo "  check    Проверить и почистить stale PID/state (по умолчанию)"
    echo "  start    Запустить hook relay + почистить stale"
    echo "  stop     Остановить hook relay"
    echo "  restart  Перезапустить relay"
    echo "  status   Показать состояние"
    ;;
  *)
    echo "Неизвестная команда: $1 (используйте help)"
    exit 1
    ;;
esac

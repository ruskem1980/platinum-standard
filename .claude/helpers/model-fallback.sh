#!/bin/bash
# model-fallback.sh — Автоматическое переключение моделей при лимитах
#
# Цепочка fallback:
#   Claude (haiku/sonnet/opus) лимит → Gemini 3 Flash/Pro
#   Gemini лимит → Opus
#   Opus лимит → ждать (уведомление)
#
# Использование:
#   bash model-fallback.sh get <задача>       — получить доступную модель
#   bash model-fallback.sh block <модель>     — пометить модель как заблокированную
#   bash model-fallback.sh unblock <модель>   — разблокировать модель
#   bash model-fallback.sh status             — показать состояние всех моделей
#   bash model-fallback.sh reset              — сбросить все блокировки
#   bash model-fallback.sh detect <вывод>     — проверить вывод на rate limit ошибки

STATE_FILE="/tmp/platinum-model-state.json"
LOG="/tmp/claude-flow-hooks.log"
BLOCK_MINUTES="${BLOCK_MINUTES:-15}"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [fallback] $1" >> "$LOG"
}

# Инициализация state файла
init_state() {
  if [ ! -f "$STATE_FILE" ]; then
    cat > "$STATE_FILE" << 'INIT'
{
  "models": {
    "haiku": {"available": true, "blocked_until": 0, "fallback": "gemini-flash"},
    "sonnet": {"available": true, "blocked_until": 0, "fallback": "gemini-flash"},
    "opus": {"available": true, "blocked_until": 0, "fallback": "gemini-pro"},
    "gemini-flash": {"available": true, "blocked_until": 0, "fallback": "gemini-pro"},
    "gemini-pro": {"available": true, "blocked_until": 0, "fallback": "opus"}
  },
  "fallback_chain": {
    "search":       ["haiku", "gemini-flash", "sonnet", "opus"],
    "docs":         ["haiku", "gemini-flash", "sonnet", "opus"],
    "tests":        ["haiku", "gemini-flash", "sonnet", "opus"],
    "analyze":      ["gemini-flash", "sonnet", "gemini-pro", "opus"],
    "review":       ["gemini-flash", "sonnet", "gemini-pro", "opus"],
    "audit":        ["gemini-flash", "sonnet", "gemini-pro", "opus"],
    "coding":       ["sonnet", "gemini-flash", "gemini-pro", "opus"],
    "refactoring":  ["sonnet", "gemini-flash", "gemini-pro", "opus"],
    "architecture": ["gemini-pro", "sonnet", "opus"],
    "security":     ["opus", "gemini-pro", "sonnet"],
    "default":      ["sonnet", "gemini-flash", "gemini-pro", "opus"]
  },
  "stats": {
    "total_fallbacks": 0,
    "last_fallback": null
  }
}
INIT
    log "State инициализирован: $STATE_FILE"
  fi
}

# Получить текущий timestamp (секунды)
now_ts() {
  date +%s
}

# Разблокировать модели с истёкшим таймаутом
auto_unblock() {
  local now=$(now_ts)
  python3 -c "
import json, sys
with open('$STATE_FILE', 'r') as f:
    state = json.load(f)
changed = False
for name, m in state['models'].items():
    if not m['available'] and m['blocked_until'] > 0 and m['blocked_until'] <= $now:
        m['available'] = True
        m['blocked_until'] = 0
        changed = True
        print(f'  [auto-unblock] {name} разблокирован (таймаут истёк)', file=sys.stderr)
if changed:
    with open('$STATE_FILE', 'w') as f:
        json.dump(state, f, indent=2)
" 2>>"$LOG"
}

# Получить лучшую доступную модель для задачи
get_model() {
  local task="${1:-default}"
  init_state
  auto_unblock

  local result
  result=$(python3 -c "
import json, sys
with open('$STATE_FILE', 'r') as f:
    state = json.load(f)
task = '$task'
chain = state['fallback_chain'].get(task, state['fallback_chain']['default'])
for model in chain:
    if state['models'].get(model, {}).get('available', False):
        print(model)
        sys.exit(0)
# Все заблокированы — вернуть последнюю в цепочке (лучше хоть что-то)
print(chain[-1])
print('WARNING: все модели заблокированы, используется ' + chain[-1], file=sys.stderr)
" 2>>"$LOG")

  echo "$result"
}

# Заблокировать модель на N минут
block_model() {
  local model="$1"
  local minutes="${2:-$BLOCK_MINUTES}"
  init_state

  local until=$(( $(now_ts) + minutes * 60 ))

  python3 -c "
import json
with open('$STATE_FILE', 'r') as f:
    state = json.load(f)
if '$model' in state['models']:
    state['models']['$model']['available'] = False
    state['models']['$model']['blocked_until'] = $until
    state['stats']['total_fallbacks'] = state['stats'].get('total_fallbacks', 0) + 1
    state['stats']['last_fallback'] = '$model'
    with open('$STATE_FILE', 'w') as f:
        json.dump(state, f, indent=2)
    # Определяем fallback
    fb = state['models']['$model'].get('fallback', 'opus')
    avail = state['models'].get(fb, {}).get('available', True)
    print(f'{fb}' if avail else 'opus')
else:
    print('opus')
"

  log "BLOCK: $model на ${minutes}мин (до $(date -d @$until 2>/dev/null || date -r $until '+%H:%M:%S'))"
  echo ""
  echo "  ⚠ $model заблокирован на ${minutes} минут"

  # Определяем и показываем fallback
  local fb=$(python3 -c "
import json
with open('$STATE_FILE', 'r') as f:
    state = json.load(f)
m = state['models'].get('$model', {})
fb = m.get('fallback', 'opus')
print(fb)
")
  echo "  → Fallback: $fb"
}

# Разблокировать модель
unblock_model() {
  local model="$1"
  init_state

  python3 -c "
import json
with open('$STATE_FILE', 'r') as f:
    state = json.load(f)
if '$model' in state['models']:
    state['models']['$model']['available'] = True
    state['models']['$model']['blocked_until'] = 0
with open('$STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
"

  log "UNBLOCK: $model"
  echo "  ✓ $model разблокирован"
}

# Детекция rate limit в выводе команды
detect_rate_limit() {
  local output="$1"
  local model="${2:-unknown}"

  # Паттерны rate limit ошибок
  local is_limited=false
  local reason=""

  # Claude API
  if echo "$output" | grep -qiE "rate.?limit|429|too.?many.?requests|quota.?exceeded|overloaded|capacity"; then
    is_limited=true
    reason="rate limit / 429"
  fi

  # Gemini CLI
  if echo "$output" | grep -qiE "RESOURCE_EXHAUSTED|quota|429|rate.?limit|daily.?limit"; then
    is_limited=true
    reason="Gemini quota exhausted"
  fi

  # Anthropic specific
  if echo "$output" | grep -qiE "credit.?balance|billing|insufficient.?credits|account.?limit"; then
    is_limited=true
    reason="billing / credits"
  fi

  if [ "$is_limited" = true ]; then
    log "RATE LIMIT обнаружен: model=$model reason=$reason"
    block_model "$model"
    return 0  # true — лимит обнаружен
  fi

  return 1  # false — всё ок
}

# Показать статус всех моделей
show_status() {
  init_state
  auto_unblock

  echo "=== Model Fallback Status ==="
  echo ""

  python3 -c "
import json, time
with open('$STATE_FILE', 'r') as f:
    state = json.load(f)

now = int(time.time())
print('  Модель           Статус      Блокировка')
print('  ─────────────────────────────────────────')
for name, m in state['models'].items():
    status = '✓ доступна' if m['available'] else '✗ заблокирована'
    blocked = ''
    if not m['available'] and m['blocked_until'] > 0:
        remaining = m['blocked_until'] - now
        if remaining > 0:
            mins = remaining // 60
            secs = remaining % 60
            blocked = f'ещё {mins}м {secs}с'
        else:
            blocked = 'истекла'
    fb = m.get('fallback', '—')
    print(f'  {name:<17} {status:<15} {blocked:<15} → {fb}')

print()
print(f'  Всего fallback-ов: {state[\"stats\"].get(\"total_fallbacks\", 0)}')
last = state['stats'].get('last_fallback')
if last:
    print(f'  Последний:         {last}')
"

  echo ""
  echo "  Цепочки fallback:"
  echo "    Claude (haiku/sonnet) → Gemini Flash → Gemini Pro → Opus"
  echo "    Gemini Flash → Gemini Pro → Opus"
  echo "    Gemini Pro → Opus"
  echo "    Opus → (ожидание, нет fallback)"
  echo ""
  echo "==========================="
}

# Сброс всех блокировок
reset_all() {
  rm -f "$STATE_FILE"
  init_state
  log "RESET: все блокировки сброшены"
  echo "  ✓ Все модели разблокированы"
}

# Обработка команд
case "${1:-status}" in
  "get")
    get_model "$2"
    ;;
  "block")
    if [ -z "$2" ]; then
      echo "Использование: bash model-fallback.sh block <модель> [минуты]"
      echo "Модели: haiku, sonnet, opus, gemini-flash, gemini-pro"
      exit 1
    fi
    block_model "$2" "${3:-$BLOCK_MINUTES}"
    ;;
  "unblock")
    if [ -z "$2" ]; then
      echo "Использование: bash model-fallback.sh unblock <модель>"
      exit 1
    fi
    unblock_model "$2"
    ;;
  "detect")
    detect_rate_limit "$2" "$3"
    ;;
  "status")
    show_status
    ;;
  "reset")
    reset_all
    ;;
  "chain")
    # Показать цепочку для задачи
    task="${2:-default}"
    init_state
    python3 -c "
import json
with open('$STATE_FILE', 'r') as f:
    state = json.load(f)
chain = state['fallback_chain'].get('$task', state['fallback_chain']['default'])
for i, m in enumerate(chain):
    avail = state['models'].get(m, {}).get('available', True)
    mark = '✓' if avail else '✗'
    arrow = '→' if i < len(chain) - 1 else ''
    print(f'  {mark} {m} {arrow}')
"
    ;;
  "help"|"-h"|"--help")
    echo "model-fallback.sh — Автоматическое переключение моделей при лимитах"
    echo ""
    echo "Команды:"
    echo "  get <задача>         Получить лучшую доступную модель"
    echo "  block <модель> [мин] Заблокировать модель (по умолчанию 15 мин)"
    echo "  unblock <модель>     Разблокировать модель"
    echo "  detect <вывод> [модель]  Проверить вывод на rate limit"
    echo "  status               Показать состояние всех моделей"
    echo "  reset                Сбросить все блокировки"
    echo "  chain <задача>       Показать цепочку fallback для задачи"
    echo ""
    echo "Задачи: search, docs, tests, analyze, review, audit,"
    echo "        coding, refactoring, architecture, security, default"
    echo ""
    echo "Модели: haiku, sonnet, opus, gemini-flash, gemini-pro"
    echo ""
    echo "Цепочка: Claude → Gemini 3 → Opus"
    echo "ENV: BLOCK_MINUTES=15 (длительность блокировки)"
    ;;
  *)
    echo "Неизвестная команда: $1 (используйте help)"
    exit 1
    ;;
esac

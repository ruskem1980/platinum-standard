#!/bin/bash
# gemini-router.sh — Роутинг задач на Gemini CLI (бесплатно, 1M контекст)
#
# Использование:
#   bash gemini-router.sh analyze <path>              — анализ модуля
#   bash gemini-router.sh review <path>               — code review
#   bash gemini-router.sh audit <path>                — security аудит
#   bash gemini-router.sh docs <path>                 — генерация docs
#   bash gemini-router.sh bugs <path>                 — поиск багов
#   bash gemini-router.sh architecture                — обзор архитектуры (Pro)
#   bash gemini-router.sh custom "<prompt>" <path>    — произвольный промпт
#
# Модели:
#   gemini-2.5-flash — анализ, review, docs, баги (быстро, бесплатно)
#   gemini-2.5-pro   — архитектура, глубокий анализ (экономить!)

LOG="/tmp/claude-flow-hooks.log"
FLASH="gemini-2.5-flash"
PRO="gemini-2.5-pro"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [gemini] $1" >> "$LOG"
}

# Собрать файлы из пути (рекурсивно, только .py/.ts/.js/.tsx, без миграций)
collect_files() {
  local target="$1"
  if [ -f "$target" ]; then
    cat "$target"
  elif [ -d "$target" ]; then
    find "$target" -type f \( -name "*.py" -o -name "*.ts" -o -name "*.tsx" -o -name "*.js" \) \
      -not -path "*/migrations/*" \
      -not -path "*/__pycache__/*" \
      -not -path "*/node_modules/*" \
      -not -path "*/.next/*" \
      -not -name "*.min.js" | \
      sort | head -60 | xargs cat 2>/dev/null
  else
    echo "Путь не найден: $target"
    return 1
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FALLBACK_SCRIPT="$SCRIPT_DIR/model-fallback.sh"

# Вызов Gemini с промптом и файлами + автоматический fallback при лимите
call_gemini() {
  local model="$1"
  local prompt="$2"
  local target="$3"

  log "CALL: model=$model target=$target prompt=${prompt:0:50}..."

  local output
  local exit_code

  if [ -n "$target" ]; then
    output=$(collect_files "$target" | gemini -p "$prompt" --model "$model" -y 2>&1)
    exit_code=$?
  else
    output=$(gemini -p "$prompt" --model "$model" -y 2>&1)
    exit_code=$?
  fi

  # Проверяем на rate limit
  if [ $exit_code -ne 0 ] || echo "$output" | grep -qiE "RESOURCE_EXHAUSTED|429|rate.?limit|quota|daily.?limit"; then
    # Определяем имя модели для fallback
    local fb_name="gemini-flash"
    if echo "$model" | grep -qi "pro"; then
      fb_name="gemini-pro"
    fi

    log "RATE LIMIT: model=$model exit=$exit_code — запускаю fallback"

    # Блокируем модель
    if [ -f "$FALLBACK_SCRIPT" ]; then
      bash "$FALLBACK_SCRIPT" block "$fb_name" 15 >> "$LOG" 2>&1
    fi

    # Fallback: gemini-flash → gemini-pro → opus (через cf-hook.sh / npx)
    if [ "$fb_name" = "gemini-flash" ]; then
      log "FALLBACK: gemini-flash → gemini-pro"
      echo "$output" | head -1
      echo ""
      echo "⚠ Gemini Flash лимит исчерпан. Переключаюсь на Gemini Pro..."
      echo ""

      if [ -n "$target" ]; then
        output=$(collect_files "$target" | gemini -p "$prompt" --model "$PRO" -y 2>&1)
        exit_code=$?
      else
        output=$(gemini -p "$prompt" --model "$PRO" -y 2>&1)
        exit_code=$?
      fi

      # Если и Pro не работает — fallback на Opus через уведомление
      if [ $exit_code -ne 0 ] || echo "$output" | grep -qiE "RESOURCE_EXHAUSTED|429|rate.?limit|quota"; then
        log "FALLBACK: gemini-pro тоже заблокирован → opus (уведомление)"
        if [ -f "$FALLBACK_SCRIPT" ]; then
          bash "$FALLBACK_SCRIPT" block "gemini-pro" 15 >> "$LOG" 2>&1
        fi
        echo "⚠ Все Gemini модели недоступны. Используйте Claude Opus:"
        echo "  → В Claude Code: Task с subagent_type и model='opus'"
        echo "  → Или подождите 15 минут для сброса лимитов"
        echo ""
        echo "  Проверить статус: bash .claude/helpers/model-fallback.sh status"
        return 1
      fi
    else
      # gemini-pro заблокирован → уведомление об opus
      log "FALLBACK: gemini-pro → opus (уведомление)"
      if [ -f "$FALLBACK_SCRIPT" ]; then
        bash "$FALLBACK_SCRIPT" block "gemini-pro" 15 >> "$LOG" 2>&1
      fi
      echo "⚠ Gemini Pro лимит исчерпан. Используйте Claude Opus:"
      echo "  → В Claude Code: Task с subagent_type и model='opus'"
      echo "  → Или подождите 15 минут для сброса лимитов"
      return 1
    fi
  fi

  echo "$output"
  log "DONE: model=$model exit=$exit_code"
  return $exit_code
}

# Команды
case "${1:-help}" in
  "analyze")
    call_gemini "$FLASH" \
      "Проанализируй этот код. Для каждого файла опиши:
1. Назначение и ответственность
2. Зависимости (импорты, внешние сервисы)
3. Потенциальные проблемы (баги, race conditions, утечки)
4. Рекомендации по улучшению
Формат: markdown с заголовками для каждого файла." \
      "$2"
    ;;

  "review")
    call_gemini "$FLASH" \
      "Проведи code review. Проверь:
1. Качество кода (naming, структура, DRY)
2. Обработка ошибок (try/except, edge cases)
3. Безопасность (инъекции, секреты, валидация)
4. Производительность (N+1 запросы, утечки памяти)
5. Тестируемость
Для каждой проблемы: файл, строка, серьёзность (critical/high/medium/low), описание, fix." \
      "$2"
    ;;

  "audit")
    call_gemini "$FLASH" \
      "Security аудит кода. Проверь OWASP Top 10:
1. Injection (SQL, command, template)
2. Broken Authentication
3. Sensitive Data Exposure (секреты, токены, .env)
4. XXE, SSRF, CSRF
5. Security Misconfiguration
6. XSS
7. Insecure Deserialization
8. Insufficient Logging
Для каждой уязвимости: severity (CRITICAL/HIGH/MEDIUM/LOW), файл, строка, описание, remediation." \
      "$2"
    ;;

  "docs")
    call_gemini "$FLASH" \
      "Сгенерируй документацию для этого кода:
1. Описание модуля (1-2 абзаца)
2. API endpoints (если есть) — метод, URL, параметры, ответ
3. Модели данных (если есть) — поля, типы, связи
4. Примеры использования
5. Конфигурация и зависимости
Формат: markdown." \
      "$2"
    ;;

  "bugs")
    call_gemini "$FLASH" \
      "Найди все потенциальные баги в этом коде. Для каждого бага:
1. Файл и строка
2. Серьёзность (critical/high/medium/low)
3. Описание проблемы
4. Воспроизведение (когда сработает)
5. Предложенный fix (код)" \
      "$2"
    ;;

  "architecture")
    # Pro модель для глубокого анализа
    local target="${2:-.}"
    call_gemini "$PRO" \
      "Опиши архитектуру проекта:
1. Общая структура (модули, слои)
2. Зависимости между модулями (граф)
3. Паттерны (DDD, CQRS, Event Sourcing и т.д.)
4. Потенциальные архитектурные проблемы
5. Рекомендации по улучшению
Формат: markdown с диаграммами (mermaid)." \
      "$target"
    ;;

  "custom")
    local prompt="$2"
    local target="$3"
    local model="${4:-$FLASH}"
    if [ -z "$prompt" ]; then
      echo "Использование: bash gemini-router.sh custom \"<промпт>\" <путь> [модель]"
      exit 1
    fi
    call_gemini "$model" "$prompt" "$target"
    ;;

  "stats")
    # Статистика вызовов из лога
    echo "=== Gemini Router Stats ==="
    if [ -f "$LOG" ]; then
      local total=$(grep -c "\[gemini\] CALL:" "$LOG" 2>/dev/null || echo 0)
      local done=$(grep -c "\[gemini\] DONE:" "$LOG" 2>/dev/null || echo 0)
      local flash=$(grep "\[gemini\] CALL:.*flash" "$LOG" 2>/dev/null | wc -l | tr -d ' ')
      local pro=$(grep "\[gemini\] CALL:.*pro" "$LOG" 2>/dev/null | wc -l | tr -d ' ')
      echo "  Total calls: $total"
      echo "  Completed:   $done"
      echo "  Flash:       $flash"
      echo "  Pro:         $pro"
    else
      echo "  Нет данных (лог пуст)"
    fi
    echo "==========================="
    ;;

  "help"|"-h"|"--help")
    echo "gemini-router.sh — Роутинг задач на Gemini CLI"
    echo ""
    echo "Команды:"
    echo "  analyze <path>              Анализ модуля (Flash)"
    echo "  review <path>               Code review (Flash)"
    echo "  audit <path>                Security аудит (Flash)"
    echo "  docs <path>                 Генерация docs (Flash)"
    echo "  bugs <path>                 Поиск багов (Flash)"
    echo "  architecture [path]         Обзор архитектуры (Pro)"
    echo "  custom \"prompt\" <path>      Произвольный запрос"
    echo "  stats                       Статистика вызовов"
    echo ""
    echo "Модели:"
    echo "  Flash (бесплатно, быстро) — анализ, review, docs"
    echo "  Pro (бесплатно, глубоко)  — архитектура, сложный анализ"
    ;;

  *)
    echo "Неизвестная команда: $1 (используйте help)"
    exit 1
    ;;
esac

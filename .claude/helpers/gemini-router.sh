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

# Вызов Gemini с промптом и файлами
call_gemini() {
  local model="$1"
  local prompt="$2"
  local target="$3"

  log "CALL: model=$model target=$target prompt=${prompt:0:50}..."

  if [ -n "$target" ]; then
    collect_files "$target" | gemini -p "$prompt" --model "$model" -y 2>/dev/null
  else
    gemini -p "$prompt" --model "$model" -y 2>/dev/null
  fi

  local exit_code=$?
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

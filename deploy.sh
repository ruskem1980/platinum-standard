#!/bin/bash
# deploy.sh — Массовая установка Platinum Standard на все проекты + git push
#
# Использование:
#   bash deploy.sh                          — установить на все git-проекты в ~/Desktop/Проекты/
#   bash deploy.sh /path/to/project1 ...    — установить на конкретные проекты
#   PROJECTS_DIR=/other/dir bash deploy.sh  — сканировать другую директорию

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECTS_DIR="${PROJECTS_DIR:-$HOME/Desktop/Проекты}"
LOG="/tmp/platinum-standard-deploy.log"
RESULTS=()
ERRORS=()

echo "=============================================="
echo "  Platinum Standard — Массовая установка"
echo "=============================================="
echo ""
echo "  Источник:  $SCRIPT_DIR"
echo "  Проекты:   $PROJECTS_DIR"
echo "  Дата:      $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Начало деплоя" > "$LOG"

# Собираем список проектов
if [ $# -gt 0 ]; then
  # Конкретные проекты из аргументов
  PROJECTS=("$@")
else
  # Автоматический поиск git-репозиториев с remote
  PROJECTS=()
  for dir in "$PROJECTS_DIR"/*/; do
    if [ -d "$dir/.git" ]; then
      remote=$(cd "$dir" && git remote get-url origin 2>/dev/null || echo "")
      if [ -n "$remote" ]; then
        PROJECTS+=("$dir")
      fi
    fi
  done
fi

echo "  Найдено проектов: ${#PROJECTS[@]}"
echo ""

# Установка на каждый проект
for project in "${PROJECTS[@]}"; do
  project=$(echo "$project" | sed 's|/$||') # убираем trailing slash
  name=$(basename "$project")

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  [$name]"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [ ! -d "$project/.git" ]; then
    echo "  ⚠ Не git-репозиторий — пропускаю"
    ERRORS+=("$name: не git-репозиторий")
    continue
  fi

  # 1. Копируем helpers
  echo "  [1] Копирую helpers..."
  mkdir -p "$project/.claude/helpers"

  for file in cf-hook.sh hook-relay.mjs daemon-watchdog.sh gemini-router.sh; do
    if [ -f "$SCRIPT_DIR/.claude/helpers/$file" ]; then
      cp "$SCRIPT_DIR/.claude/helpers/$file" "$project/.claude/helpers/$file"
    fi
  done
  chmod +x "$project/.claude/helpers/"*.sh 2>/dev/null || true
  echo "    ✓ helpers скопированы"

  # 2. settings.json — копируем шаблон если нет существующего
  if [ ! -f "$project/.claude/settings.json" ]; then
    cp "$SCRIPT_DIR/.claude/settings.template.json" "$project/.claude/settings.json"
    echo "    ✓ settings.json установлен (новый)"
  else
    # Обновляем settings.template.json для справки
    cp "$SCRIPT_DIR/.claude/settings.template.json" "$project/.claude/settings.template.json"
    echo "    ✓ settings.template.json обновлён (settings.json не тронут)"
  fi

  # 3. Тесты
  if [ -d "$SCRIPT_DIR/tests/test_spawn_system" ]; then
    mkdir -p "$project/tests/test_spawn_system"
    cp "$SCRIPT_DIR/tests/test_spawn_system/"*.py "$project/tests/test_spawn_system/"
    echo "    ✓ тесты скопированы"
  fi

  # 4. Git commit + push
  echo "  [2] Git commit + push..."
  cd "$project"

  # Проверяем есть ли изменения
  if git diff --quiet HEAD -- .claude/ tests/test_spawn_system/ 2>/dev/null && \
     [ -z "$(git ls-files --others --exclude-standard .claude/ tests/test_spawn_system/)" ]; then
    echo "    ⚠ Нет изменений — пропускаю push"
    RESULTS+=("$name: уже актуален")
    continue
  fi

  git add .claude/helpers/ .claude/settings.json .claude/settings.template.json tests/test_spawn_system/ 2>/dev/null || true
  git add .claude/helpers/ tests/test_spawn_system/ 2>/dev/null || true

  if git diff --cached --quiet 2>/dev/null; then
    # Есть untracked файлы
    git add .claude/ tests/test_spawn_system/ 2>/dev/null || true
  fi

  git commit -m "feat: установка Platinum Standard spawn-системы

- hook-relay.mjs v2 (lock file, /metrics, /health)
- daemon-watchdog.sh (orphan cleanup, auto-find states)
- cf-hook.sh (socket relay ~5ms, npx fallback ~2s)
- gemini-router.sh (Gemini CLI бесплатный анализ)
- 41 тест без LLM (latency, zombie, efficiency)

Co-Authored-By: claude-flow <ruv@ruv.net>" 2>>"$LOG" || {
    echo "    ⚠ Нечего коммитить"
    RESULTS+=("$name: нечего коммитить")
    continue
  }

  echo "    ✓ Закоммичено"

  # Push
  branch=$(git branch --show-current)
  if git push origin "$branch" 2>>"$LOG"; then
    echo "    ✓ Запушено в origin/$branch"
    RESULTS+=("$name: ✓ установлен + push ($branch)")
  else
    echo "    ✗ Ошибка push"
    ERRORS+=("$name: push не удался")
    RESULTS+=("$name: ✓ установлен, ✗ push не удался")
  fi

  echo ""
done

# Итог
echo ""
echo "=============================================="
echo "  РЕЗУЛЬТАТЫ"
echo "=============================================="
echo ""
for r in "${RESULTS[@]}"; do
  echo "  $r"
done

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo ""
  echo "  ОШИБКИ:"
  for e in "${ERRORS[@]}"; do
    echo "  ✗ $e"
  done
fi

echo ""
echo "  Всего проектов:  ${#PROJECTS[@]}"
echo "  Успешно:         $((${#PROJECTS[@]} - ${#ERRORS[@]}))"
echo "  Ошибки:          ${#ERRORS[@]}"
echo ""
echo "  Лог: $LOG"
echo "=============================================="

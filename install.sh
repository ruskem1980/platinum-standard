#!/bin/bash
# install.sh — Установка Platinum Standard spawn-системы в проект
#
# Использование:
#   cd /path/to/your/project
#   bash /path/to/platinum-standard/install.sh
#
# Или из клонированного репо:
#   bash install.sh /path/to/target/project

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$(pwd)}"

echo "=== Platinum Standard — Установка spawn-системы ==="
echo ""
echo "  Источник: $SCRIPT_DIR"
echo "  Цель:     $TARGET"
echo ""

# Проверки
if [ ! -d "$TARGET" ]; then
  echo "ОШИБКА: Директория $TARGET не существует"
  exit 1
fi

# Создаём структуру
mkdir -p "$TARGET/.claude/helpers"

# Копируем helpers
echo "  [1/5] Копирую helpers..."
for file in cf-hook.sh hook-relay.mjs daemon-watchdog.sh gemini-router.sh model-fallback.sh; do
  cp "$SCRIPT_DIR/.claude/helpers/$file" "$TARGET/.claude/helpers/$file"
  echo "    ✓ $file"
done

# Делаем исполняемыми
chmod +x "$TARGET/.claude/helpers/"*.sh

# Копируем шаблон настроек (если нет существующего)
echo "  [2/5] Настройки..."
if [ -f "$TARGET/.claude/settings.json" ]; then
  echo "    ⚠ settings.json уже существует — пропускаю (шаблон: .claude/settings.template.json)"
  cp "$SCRIPT_DIR/.claude/settings.template.json" "$TARGET/.claude/settings.template.json"
else
  cp "$SCRIPT_DIR/.claude/settings.template.json" "$TARGET/.claude/settings.json"
  echo "    ✓ settings.json установлен"
fi

# Копируем тесты (опционально)
echo "  [3/5] Тесты..."
if [ -d "$SCRIPT_DIR/tests/test_spawn_system" ]; then
  mkdir -p "$TARGET/tests/test_spawn_system"
  cp "$SCRIPT_DIR/tests/test_spawn_system/"*.py "$TARGET/tests/test_spawn_system/"
  echo "    ✓ Тесты скопированы в tests/test_spawn_system/"
fi

# Проверяем зависимости
echo "  [4/5] Проверка зависимостей..."
missing=""

if command -v node >/dev/null 2>&1; then
  echo "    ✓ Node.js $(node -v)"
else
  missing="$missing node"
  echo "    ✗ Node.js не найден"
fi

if command -v curl >/dev/null 2>&1; then
  echo "    ✓ curl"
else
  missing="$missing curl"
  echo "    ✗ curl не найден"
fi

if command -v python3 >/dev/null 2>&1; then
  echo "    ✓ Python $(python3 --version 2>&1 | cut -d' ' -f2)"
else
  missing="$missing python3"
  echo "    ✗ Python3 не найден"
fi

if command -v gemini >/dev/null 2>&1; then
  echo "    ✓ Gemini CLI"
else
  echo "    ⚠ Gemini CLI не найден (опционально, для бесплатного анализа)"
  echo "      Установка: npm install -g @anthropic-ai/gemini-cli"
fi

if [ -n "$missing" ]; then
  echo ""
  echo "  ⚠ Отсутствующие зависимости: $missing"
  echo "    Spawn-система будет работать с ограничениями"
fi

# Быстрый тест
echo "  [5/5] Быстрый тест..."
cd "$TARGET"
bash .claude/helpers/daemon-watchdog.sh check 2>/dev/null && echo "    ✓ Watchdog работает" || echo "    ⚠ Watchdog вернул ошибку"

echo ""
echo "=== Установка завершена ==="
echo ""
echo "Следующие шаги:"
echo "  1. Запустить relay: bash .claude/helpers/daemon-watchdog.sh start"
echo "  2. Проверить статус: bash .claude/helpers/daemon-watchdog.sh status"
echo "  3. Запустить тесты:  cd $TARGET && python3 -m pytest tests/test_spawn_system/ -v"
echo "  4. Gemini анализ:    bash .claude/helpers/gemini-router.sh analyze src/"
echo ""

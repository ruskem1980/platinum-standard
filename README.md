# Platinum Standard

Портативная spawn-система для Claude Code — hook relay, watchdog, Gemini роутинг, автоматический fallback моделей, авто-обучение, 41 тест без LLM.

---

## Что это

Набор скриптов, которые ускоряют работу Claude Code в любом проекте:

- **Hook Relay** — Unix socket сервер, кеширует CLI и отвечает за ~270ms вместо ~2000ms через npx
- **Watchdog** — убивает zombie/orphan процессы, управляет жизненным циклом relay
- **Gemini Router** — бесплатный анализ кода через Gemini CLI (1M токенов контекст, 1000 запросов/день)
- **Auto-learning** — сохраняет паттерны успешных задач в memory для будущих сессий
- **Model Fallback** — автоматическое переключение при лимитах: Claude → Gemini 3 → Opus
- **41 тест** — проверка latency, throughput, zombie detection, efficiency score без LLM

---

## Быстрая установка

### Вариант 1 — Скрипт (рекомендуется)

```bash
git clone https://github.com/ruskem1980/platinum-standard.git /tmp/platinum-standard
cd /path/to/your/project
bash /tmp/platinum-standard/install.sh
```

### Вариант 2 — Ручная

```bash
# 1. Скопировать helpers
mkdir -p .claude/helpers
curl -sL https://raw.githubusercontent.com/ruskem1980/platinum-standard/main/.claude/helpers/cf-hook.sh -o .claude/helpers/cf-hook.sh
curl -sL https://raw.githubusercontent.com/ruskem1980/platinum-standard/main/.claude/helpers/hook-relay.mjs -o .claude/helpers/hook-relay.mjs
curl -sL https://raw.githubusercontent.com/ruskem1980/platinum-standard/main/.claude/helpers/daemon-watchdog.sh -o .claude/helpers/daemon-watchdog.sh
curl -sL https://raw.githubusercontent.com/ruskem1980/platinum-standard/main/.claude/helpers/gemini-router.sh -o .claude/helpers/gemini-router.sh
curl -sL https://raw.githubusercontent.com/ruskem1980/platinum-standard/main/.claude/helpers/model-fallback.sh -o .claude/helpers/model-fallback.sh
chmod +x .claude/helpers/*.sh

# 2. Скопировать настройки (если нет .claude/settings.json)
curl -sL https://raw.githubusercontent.com/ruskem1980/platinum-standard/main/.claude/settings.template.json -o .claude/settings.json

# 3. Запустить
bash .claude/helpers/daemon-watchdog.sh start
```

### Вариант 3 — Массовая установка на все проекты

```bash
git clone https://github.com/ruskem1980/platinum-standard.git /tmp/platinum-standard
bash /tmp/platinum-standard/deploy.sh
```

`deploy.sh` автоматически найдёт все git-репозитории с remote в `~/Desktop/Проекты/`, установит файлы, закоммитит и запушит.

Для другой директории:
```bash
PROJECTS_DIR=/path/to/projects bash /tmp/platinum-standard/deploy.sh
```

---

## Структура файлов

```
.claude/
├── helpers/
│   ├── cf-hook.sh           # Быстрый executor (socket ~5ms → npx ~2s)
│   ├── hook-relay.mjs       # Unix socket сервер v2 (lock, metrics, health)
│   ├── daemon-watchdog.sh   # Управление relay, очистка zombie
│   ├── gemini-router.sh     # Gemini CLI роутинг (бесплатно) + fallback
│   └── model-fallback.sh    # Автоматический fallback при лимитах
├── settings.json            # Hooks, permissions, model routing
└── settings.template.json   # Шаблон (для справки)

tests/test_spawn_system/
├── conftest.py              # Фикстуры, автопоиск PROJECT_ROOT
├── test_hook_relay.py       # 14 тестов: latency, throughput, reliability
├── test_daemon_health.py    # 18 тестов: zombie, orphan, watchdog, log
└── test_spawn_efficiency.py # 9 тестов: ROI, overhead, efficiency 0-100
```

---

## Компоненты

### Hook Relay (`hook-relay.mjs`)

HTTP-сервер на Unix socket — принимает вызовы от Claude Code hooks и проксирует в claude-flow CLI.

**API:**
```
POST /hook    — выполнить hook-команду
GET  /health  — проверка здоровья {"ok": true, "pid": 12345}
GET  /metrics — агрегированные метрики
```

**Пример:**
```bash
# Через curl
curl -s --unix-socket /tmp/claude-flow-hook-relay.sock \
  -X POST -H "Content-Type: application/json" \
  -d '{"args": ["hooks", "statusline", "--json"]}' \
  http://localhost/hook

# Через cf-hook.sh (автоматически выбирает socket → npx)
bash .claude/helpers/cf-hook.sh hooks statusline --json
```

**Защита от дублирования:** Atomic lock file (`O_EXCL`) — если relay уже запущен, новый процесс тихо выходит без EADDRINUSE.

**Metrics ответ:**
```json
{
  "totalCalls": 42,
  "successCalls": 40,
  "errorCalls": 2,
  "avgLatencyMs": 245.3,
  "uptime": 3600,
  "persistentCliActive": false,
  "memoryMB": 56
}
```

### Watchdog (`daemon-watchdog.sh`)

Управляет жизненным циклом relay и чистит мусор.

```bash
bash .claude/helpers/daemon-watchdog.sh start    # запуск relay + очистка stale
bash .claude/helpers/daemon-watchdog.sh stop     # остановка relay
bash .claude/helpers/daemon-watchdog.sh restart  # перезапуск
bash .claude/helpers/daemon-watchdog.sh check    # очистка zombie без запуска
bash .claude/helpers/daemon-watchdog.sh status   # показать состояние
```

**Что делает `check`:**
1. Ищет все `daemon-state.json` в поддиректориях проекта
2. Если `running: true` но PID мёртв — ставит `running: false`
3. Удаляет stale PID файлы
4. Убивает orphan процессы `claude-flow.*daemon` без PID файлов
5. Убивает дубликаты MCP серверов (оставляет последние 2)

### Gemini Router (`gemini-router.sh`)

Бесплатный анализ кода через Gemini CLI (1000 запросов/день, 1M контекст).

```bash
bash .claude/helpers/gemini-router.sh analyze src/       # анализ модуля (Flash)
bash .claude/helpers/gemini-router.sh review src/api/    # code review (Flash)
bash .claude/helpers/gemini-router.sh audit src/auth/    # security аудит (Flash)
bash .claude/helpers/gemini-router.sh docs src/models/   # генерация docs (Flash)
bash .claude/helpers/gemini-router.sh bugs src/workers/  # поиск багов (Flash)
bash .claude/helpers/gemini-router.sh architecture       # обзор архитектуры (Pro)
bash .claude/helpers/gemini-router.sh stats              # статистика вызовов

# Произвольный запрос
bash .claude/helpers/gemini-router.sh custom "найди утечки памяти" src/
```

**Модели:**
| Модель | Стоимость | Когда |
|--------|-----------|-------|
| gemini-2.5-flash | Бесплатно | Анализ, review, docs, баги |
| gemini-2.5-pro | Бесплатно | Архитектура, глубокий анализ |

**Требование:** Установленный Gemini CLI (`npm install -g @anthropic-ai/gemini-cli`).

### Model Fallback (`model-fallback.sh`)

Автоматическое переключение моделей при исчерпании лимитов.

**Цепочка fallback:**
```
haiku  ──лимит──→ gemini-flash ──лимит──→ gemini-pro ──лимит──→ opus
sonnet ──лимит──→ gemini-flash ──лимит──→ gemini-pro ──лимит──→ opus
gemini-flash ──лимит──→ gemini-pro ──лимит──→ opus
gemini-pro ──лимит──→ opus
opus ──лимит──→ ожидание (уведомление)
```

**Как работает:**
1. При ошибке rate limit (429, quota exceeded) модель блокируется на 15 минут
2. Следующий вызов автоматически идёт через fallback модель
3. Gemini router при лимите переключается на следующую Gemini модель, затем уведомляет об Opus
4. Истёкшие блокировки автоматически снимаются

**Команды:**
```bash
# Посмотреть статус всех моделей
bash .claude/helpers/model-fallback.sh status

# Получить лучшую модель для задачи
bash .claude/helpers/model-fallback.sh get coding       # → sonnet (или fallback)
bash .claude/helpers/model-fallback.sh get analyze      # → gemini-flash (или fallback)
bash .claude/helpers/model-fallback.sh get architecture # → gemini-pro (или fallback)
bash .claude/helpers/model-fallback.sh get security     # → opus (или fallback)

# Вручную заблокировать/разблокировать
bash .claude/helpers/model-fallback.sh block sonnet 30    # блок на 30 мин
bash .claude/helpers/model-fallback.sh unblock sonnet
bash .claude/helpers/model-fallback.sh reset              # сбросить все блокировки

# Показать цепочку для задачи
bash .claude/helpers/model-fallback.sh chain coding

# Проверить вывод на rate limit
bash .claude/helpers/model-fallback.sh detect "429 Too Many Requests" sonnet
```

**Задачи и их цепочки:**
| Задача | Цепочка fallback |
|--------|-----------------|
| search, docs, tests | haiku → gemini-flash → sonnet → opus |
| analyze, review, audit | gemini-flash → sonnet → gemini-pro → opus |
| coding, refactoring | sonnet → gemini-flash → gemini-pro → opus |
| architecture | gemini-pro → sonnet → opus |
| security | opus → gemini-pro → sonnet |

**Состояние хранится в:** `/tmp/platinum-model-state.json`

**ENV:** `BLOCK_MINUTES=15` — длительность блокировки (по умолчанию 15 минут).

### cf-hook.sh

Быстрый executor — единая точка входа для всех hook-вызовов.

**Приоритеты:**
1. Unix socket relay (~5-50ms) — если `/tmp/claude-flow-hook-relay.sock` существует
2. npx fallback (~2000ms) — если relay не запущен

```bash
bash .claude/helpers/cf-hook.sh hooks post-edit --file "path" --success true
bash .claude/helpers/cf-hook.sh memory store --key "name" --value "data" --namespace patterns
bash .claude/helpers/cf-hook.sh memory search --query "keyword" --namespace patterns
```

---

## Интеграция с Claude Code

### settings.json

Файл `.claude/settings.json` настраивает hooks — автоматические действия Claude Code при событиях.

**Ключевые секции:**

#### SessionStart — запуск relay при открытии проекта
```json
{
  "hooks": {
    "SessionStart": [{
      "hooks": [{
        "type": "command",
        "command": "bash .claude/helpers/daemon-watchdog.sh start 2>>/tmp/claude-flow-hooks.log || true",
        "timeout": 10000,
        "continueOnError": true
      }]
    }]
  }
}
```

#### PostToolUse — отслеживание редактирования файлов
```json
{
  "PostToolUse": [{
    "matcher": "^(Write|Edit|MultiEdit)$",
    "hooks": [{
      "type": "command",
      "command": "bash .claude/helpers/cf-hook.sh hooks post-edit --file \"$TOOL_INPUT_file_path\" --success \"${TOOL_SUCCESS:-true}\" 2>>/tmp/claude-flow-hooks.log || true",
      "timeout": 5000,
      "continueOnError": true
    }]
  }]
}
```

#### Auto-learning — сохранение паттернов после успешных Task агентов
```json
{
  "PostToolUse": [{
    "matcher": "^Task$",
    "hooks": [{
      "type": "command",
      "command": "[ \"${TOOL_SUCCESS:-true}\" = \"true\" ] && bash .claude/helpers/cf-hook.sh memory store --namespace patterns --key \"task-${TOOL_INPUT_subagent_type}-$(date +%s)\" --value \"{\\\"agent\\\":\\\"$TOOL_INPUT_subagent_type\\\",\\\"success\\\":true}\" 2>>/tmp/claude-flow-hooks.log || true",
      "timeout": 5000,
      "continueOnError": true
    }]
  }]
}
```

#### Stop — остановка relay при закрытии
```json
{
  "Stop": [{
    "hooks": [{
      "type": "command",
      "command": "bash .claude/helpers/daemon-watchdog.sh stop 2>>/tmp/claude-flow-hooks.log || true",
      "timeout": 3000,
      "continueOnError": true
    }]
  }]
}
```

#### Permissions — разрешения для Bash
```json
{
  "permissions": {
    "allow": [
      "Bash(bash .claude/helpers/*)",
      "Bash(bash .claude/helpers/gemini-router.sh:*)",
      "mcp__claude-flow__:*"
    ]
  }
}
```

#### Status Line — живая строка состояния
```json
{
  "statusLine": {
    "type": "command",
    "command": "bash .claude/helpers/cf-hook.sh hooks statusline 2>/dev/null || echo \"▊ Platinum Standard\"",
    "refreshMs": 5000,
    "enabled": true
  }
}
```

Полный пример — в файле `.claude/settings.template.json`.

### Model Routing

Рекомендуемая иерархия моделей для Task агентов:

| Модель | Стоимость | Контекст | Когда |
|--------|-----------|----------|-------|
| haiku | $0.25/1M | 200K | Поиск, docs, тесты |
| gemini-flash | Бесплатно | 1M | Анализ, аудит, review (через gemini-router.sh) |
| sonnet | $3/1M | 200K | Кодинг, рефакторинг |
| gemini-pro | Бесплатно | 1M | Архитектура (через gemini-router.sh) |
| opus | $15/1M | 200K | Security, сложная архитектура |

---

## Тесты

41 тест без LLM — проверяют здоровье spawn-системы чистыми метриками.

### Запуск

```bash
# Установить pytest (если нет)
pip install pytest

# Все тесты
python3 -m pytest tests/test_spawn_system/ -v

# Только latency
python3 -m pytest tests/test_spawn_system/test_hook_relay.py -v -k "latency"

# Только zombie detection
python3 -m pytest tests/test_spawn_system/test_daemon_health.py -v -k "zombie"

# Полный аудит эффективности (генерирует отчёт 0-100)
python3 -m pytest tests/test_spawn_system/test_spawn_efficiency.py -v -k "full_efficiency"
```

### Что проверяют

**test_hook_relay.py (14 тестов):**
- Latency одиночного вызова, 10 последовательных, стабильность (CV < 1.0)
- Overhead bash wrapper vs raw socket (< 200ms)
- Throughput: 5 и 20 параллельных запросов
- Speedup sequential vs parallel
- Reliability: invalid payload, large payload (10KB+), log growth
- Memory relay < 200MB
- JSON escaping: кавычки, пробелы, кириллица

**test_daemon_health.py (18 тестов):**
- daemon-state.json — валидный JSON, running соответствует реальности
- Worker metrics — success + failure <= runCount
- Zombie detection — нет мёртвых PID с running=true
- Orphan detection — нет процессов без PID файлов
- Не более 1 relay процесса
- Суммарная память < 500MB
- Watchdog check < 2s, status выводит отчёт
- SessionStart overhead < 10s
- Нет повторяющихся ошибок в логе (> 5 одинаковых)
- Нет EADDRINUSE в логе

**test_spawn_efficiency.py (9 тестов):**
- Полный аудит: latency, память, zombies, workers, hooks/hour, patterns
- Оценка эффективности 0-100 с автоматическими штрафами/бонусами
- ROI расчёт: экономит ли relay время vs npx
- Overhead per call: estimated overhead %
- Active vs idle процессы, utilization %
- File descriptor leak (< 200 FD)
- Disk usage < 100MB
- Отчёт сохраняется в `.claude-flow/efficiency-report.json`

### Переменные окружения

```bash
# Указать корень проекта вручную (если автопоиск не работает)
PLATINUM_PROJECT_ROOT=/path/to/project python3 -m pytest tests/test_spawn_system/ -v
```

---

## Обновление

```bash
# Обновить репозиторий
cd /tmp/platinum-standard && git pull

# Переустановить на все проекты
bash deploy.sh

# Или на конкретный проект
bash install.sh /path/to/project
```

---

## Требования

| Компонент | Версия | Обязательно |
|-----------|--------|-------------|
| Node.js | 18+ | Да (relay) |
| Python 3 | 3.10+ | Да (watchdog, тесты) |
| curl | любая | Да (cf-hook.sh) |
| pytest | 7+ | Для тестов |
| Gemini CLI | 0.27+ | Нет (для gemini-router.sh) |

### Установка Gemini CLI (опционально)

```bash
npm install -g @anthropic-ai/gemini-cli
gemini  # первый запуск — OAuth авторизация
```

---

## Диагностика

```bash
# Статус моделей (fallback)
bash .claude/helpers/model-fallback.sh status

# Статус relay и daemon
bash .claude/helpers/daemon-watchdog.sh status

# Метрики relay (JSON)
curl -s --unix-socket /tmp/claude-flow-hook-relay.sock http://localhost/metrics

# Health check
curl -s --unix-socket /tmp/claude-flow-hook-relay.sock http://localhost/health

# Лог последние 20 строк
tail -20 /tmp/claude-flow-hooks.log

# Статистика Gemini вызовов
bash .claude/helpers/gemini-router.sh stats

# Полный аудит эффективности
python3 -m pytest tests/test_spawn_system/test_spawn_efficiency.py::TestSpawnEfficiencyAudit -v -s
```

---

## Архитектура

```
Claude Code
    │
    ├── SessionStart hook
    │   └── daemon-watchdog.sh start
    │       ├── cleanup stale PIDs
    │       └── start hook-relay.mjs (Unix socket)
    │
    ├── PreToolUse/Task hook
    │   └── cf-hook.sh → relay socket → CLI
    │
    ├── PostToolUse/Edit hook
    │   └── cf-hook.sh → relay socket → CLI
    │
    ├── PostToolUse/Task hook (auto-learning)
    │   └── cf-hook.sh → memory store → patterns
    │
    ├── Stop hook
    │   └── daemon-watchdog.sh stop
    │
    ├── Gemini Router (ручной вызов)
    │   └── gemini-router.sh → Gemini CLI → анализ
    │       └── rate limit? → fallback → следующая модель
    │
    └── Model Fallback (автоматический)
        └── model-fallback.sh → /tmp/platinum-model-state.json
            ├── block модель на 15 мин
            ├── auto-unblock по таймеру
            └── get → лучшая доступная модель
```

**Потоки данных:**
```
cf-hook.sh ──socket──→ hook-relay.mjs ──spawn──→ claude-flow CLI
   │                        │
   └─ npx fallback ←───── lock file (O_EXCL)
                            │
                       /metrics, /health

gemini-router.sh ──→ gemini CLI ──429──→ model-fallback.sh block
                                          │
                                    gemini-pro fallback ──429──→ opus уведомление
```

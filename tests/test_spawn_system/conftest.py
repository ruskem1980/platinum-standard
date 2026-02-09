"""Фикстуры для тестирования spawn/swarm системы без LLM.

Портативная версия — автоматически определяет PROJECT_ROOT
через переменную окружения или поиск .claude/helpers/.
"""

import json
import os
import subprocess
import time
from pathlib import Path
from typing import Any

import pytest

# Определяем PROJECT_ROOT: env → поиск вверх от текущей директории
def _find_project_root() -> Path:
    """Найти корень проекта по наличию .claude/helpers/."""
    # 1. Переменная окружения
    env_root = os.environ.get("PLATINUM_PROJECT_ROOT")
    if env_root and Path(env_root).exists():
        return Path(env_root)

    # 2. Поиск вверх от файла тестов
    current = Path(__file__).resolve().parent
    for _ in range(10):
        if (current / ".claude" / "helpers").exists():
            return current
        parent = current.parent
        if parent == current:
            break
        current = parent

    # 3. Поиск вверх от cwd
    current = Path.cwd()
    for _ in range(10):
        if (current / ".claude" / "helpers").exists():
            return current
        parent = current.parent
        if parent == current:
            break
        current = parent

    # 4. Fallback — cwd
    return Path.cwd()


PROJECT_ROOT = _find_project_root()
HELPERS_DIR = PROJECT_ROOT / ".claude" / "helpers"
CLAUDE_FLOW_DIR = PROJECT_ROOT / ".claude-flow"

SOCKET_PATH = "/tmp/claude-flow-hook-relay.sock"
PID_FILE = "/tmp/claude-flow-hook-relay.pid"
LOG_FILE = "/tmp/claude-flow-hooks.log"


def _find_daemon_state_files() -> list[Path]:
    """Автоматический поиск daemon-state.json файлов."""
    states = []
    for root, dirs, files in os.walk(str(PROJECT_ROOT)):
        # Ограничиваем глубину
        depth = root[len(str(PROJECT_ROOT)):].count(os.sep)
        if depth > 4:
            dirs.clear()
            continue
        if "daemon-state.json" in files and ".claude-flow" in root:
            states.append(Path(root) / "daemon-state.json")
    return states


DAEMON_STATE_FILES = _find_daemon_state_files()


def send_socket_request(args: list[str], timeout: float = 5.0) -> dict[str, Any]:
    """Отправить запрос через Unix socket к hook relay (через curl)."""
    payload = json.dumps({"args": args})

    try:
        result = subprocess.run(
            [
                "curl", "-s", "--max-time", str(int(timeout)),
                "--unix-socket", SOCKET_PATH,
                "-X", "POST",
                "-H", "Content-Type: application/json",
                "-d", payload,
                "http://localhost/hook",
            ],
            capture_output=True,
            text=True,
            timeout=timeout + 1,
        )
        if result.returncode == 0 and result.stdout:
            return json.loads(result.stdout)
        return {"ok": False, "error": f"curl exit={result.returncode}", "stderr": result.stderr}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "timeout"}
    except json.JSONDecodeError:
        return {"ok": False, "error": "invalid json", "raw": result.stdout[:200]}


def call_cf_hook(args: list[str], timeout: float = 10.0) -> subprocess.CompletedProcess:
    """Вызвать cf-hook.sh с аргументами."""
    return subprocess.run(
        ["bash", str(HELPERS_DIR / "cf-hook.sh"), *args],
        capture_output=True,
        text=True,
        timeout=timeout,
        cwd=str(PROJECT_ROOT),
    )


def read_daemon_state(state_path: Path) -> dict[str, Any]:
    """Прочитать daemon-state.json."""
    if not state_path.exists():
        return {}
    with open(state_path) as f:
        return json.load(f)


@pytest.fixture
def relay_running():
    """Проверяет что hook relay запущен, иначе skip."""
    if not Path(SOCKET_PATH).exists():
        pytest.skip("Hook relay не запущен (socket отсутствует)")
    # Проверяем PID
    if Path(PID_FILE).exists():
        pid = int(Path(PID_FILE).read_text().strip())
        try:
            os.kill(pid, 0)  # проверка без убийства
        except OSError:
            pytest.skip(f"Hook relay PID {pid} мёртв")
    return True


@pytest.fixture
def daemon_states() -> list[dict]:
    """Загрузить все daemon-state.json."""
    states = []
    for path in DAEMON_STATE_FILES:
        states.append({"path": str(path), "data": read_daemon_state(path)})
    return states


@pytest.fixture
def log_snapshot():
    """Снапшот лога перед тестом (для сравнения после)."""
    if Path(LOG_FILE).exists():
        lines = Path(LOG_FILE).read_text().splitlines()
        return len(lines)
    return 0


class Timer:
    """Контекстный менеджер для замера времени."""

    def __init__(self):
        self.start = 0
        self.end = 0
        self.elapsed_ms = 0

    def __enter__(self):
        self.start = time.perf_counter()
        return self

    def __exit__(self, *args):
        self.end = time.perf_counter()
        self.elapsed_ms = (self.end - self.start) * 1000


@pytest.fixture
def timer():
    """Фабрика таймеров для замера latency."""
    return Timer

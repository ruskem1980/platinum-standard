"""Тесты здоровья daemon-системы — без LLM, чистый анализ состояния.

Проверяет:
- Zombie процессы
- Stale PID файлы
- Корректность daemon-state.json
- Ресурсы (память, FD)
- Watchdog функциональность
"""

import json
import os
import re
import subprocess
import time
from pathlib import Path

import pytest

from .conftest import (
    DAEMON_STATE_FILES,
    HELPERS_DIR,
    LOG_FILE,
    PID_FILE,
    PROJECT_ROOT,
    SOCKET_PATH,
    Timer,
    read_daemon_state,
)


# --- State validation ---


class TestDaemonStateIntegrity:
    """Проверка целостности daemon-state.json."""

    @pytest.mark.parametrize(
        "state_path", DAEMON_STATE_FILES,
        ids=lambda p: str(p).replace(str(PROJECT_ROOT) + "/", "")
    )
    def test_state_file_valid_json(self, state_path):
        """Каждый daemon-state.json — валидный JSON."""
        if not state_path.exists():
            pytest.skip(f"Файл не существует: {state_path}")

        with open(state_path) as f:
            data = json.load(f)

        assert isinstance(data, dict), f"Ожидался dict, получен {type(data)}"
        print(f"\n  {state_path.name}: keys={list(data.keys())}")

    @pytest.mark.parametrize(
        "state_path", DAEMON_STATE_FILES,
        ids=lambda p: str(p).replace(str(PROJECT_ROOT) + "/", "")
    )
    def test_state_running_matches_reality(self, state_path):
        """running=true/false соответствует реальному состоянию процесса."""
        if not state_path.exists():
            pytest.skip(f"Файл не существует")

        data = read_daemon_state(state_path)
        running_claim = data.get("running", False)

        pid_file = state_path.parent / "daemon.pid"
        if pid_file.exists():
            pid = int(pid_file.read_text().strip())
            try:
                os.kill(pid, 0)
                actually_running = True
            except OSError:
                actually_running = False
        else:
            actually_running = False

        print(f"\n  State says running={running_claim}")
        print(f"  PID file: {'exists' if pid_file.exists() else 'missing'}")
        print(f"  Actually running: {actually_running}")

        if running_claim and not actually_running:
            pytest.fail(
                f"ZOMBIE STATE: {state_path} claims running=true, "
                f"но процесс мёртв — нужен watchdog cleanup"
            )

    @pytest.mark.parametrize(
        "state_path", DAEMON_STATE_FILES,
        ids=lambda p: str(p).replace(str(PROJECT_ROOT) + "/", "")
    )
    def test_worker_metrics_consistency(self, state_path):
        """Метрики worker-ов непротиворечивы (success+failure <= runCount)."""
        if not state_path.exists():
            pytest.skip("Файл не существует")

        data = read_daemon_state(state_path)
        workers = data.get("workers", data.get("config", {}).get("workers", {}))

        if isinstance(workers, list):
            pytest.skip("Workers — список имён, не dict с метриками")

        for name, metrics in workers.items():
            if not isinstance(metrics, dict):
                continue
            runs = metrics.get("runCount", 0)
            success = metrics.get("successCount", 0)
            failure = metrics.get("failureCount", 0)

            print(f"  {name}: runs={runs} success={success} failure={failure}")

            assert success + failure <= runs, (
                f"Worker {name}: success({success}) + failure({failure}) > runs({runs})"
            )

            if runs > 0:
                assert success + failure > 0, (
                    f"Worker {name}: {runs} runs но 0 success и 0 failure — потерянные задачи"
                )


# --- Zombie detection ---


class TestZombieProcesses:
    """Обнаружение zombie/orphan процессов claude-flow."""

    def test_no_zombie_daemon_processes(self):
        """Нет zombie daemon процессов (PID мёртв, state = running)."""
        zombies = []

        for state_path in DAEMON_STATE_FILES:
            if not state_path.exists():
                continue
            data = read_daemon_state(state_path)
            if data.get("running"):
                pid_file = state_path.parent / "daemon.pid"
                if pid_file.exists():
                    pid = int(pid_file.read_text().strip())
                    try:
                        os.kill(pid, 0)
                    except OSError:
                        zombies.append({"state": str(state_path), "pid": pid})

        if zombies:
            msg = "ZOMBIE STATES:\n"
            for z in zombies:
                msg += f"  {z['state']}: PID {z['pid']} мёртв но state=running\n"
            pytest.fail(msg)

    def test_no_orphan_claude_flow_processes(self):
        """Нет orphan claude-flow процессов без PID файлов."""
        result = subprocess.run(
            ["pgrep", "-f", "claude-flow.*daemon"],
            capture_output=True,
            text=True,
        )

        if result.returncode != 0:
            print("\n  Нет daemon процессов — OK")
            return

        pids = [int(p) for p in result.stdout.strip().split("\n") if p.strip()]

        known_pids = set()
        if Path(PID_FILE).exists():
            known_pids.add(int(Path(PID_FILE).read_text().strip()))
        for state_path in DAEMON_STATE_FILES:
            pid_file = state_path.parent / "daemon.pid"
            if pid_file.exists():
                try:
                    known_pids.add(int(pid_file.read_text().strip()))
                except ValueError:
                    pass

        orphans = [p for p in pids if p not in known_pids]
        print(f"\n  Daemon PIDs: {pids}")
        print(f"  Known PIDs:  {known_pids}")
        print(f"  Orphans:     {orphans}")

        if orphans:
            pytest.fail(
                f"ORPHAN daemon процессы: {orphans} — нет PID файлов. "
                f"Нужно: kill {' '.join(str(p) for p in orphans)}"
            )

    def test_no_duplicate_relay_processes(self):
        """Только один hook relay процесс."""
        result = subprocess.run(
            ["pgrep", "-f", "hook-relay"],
            capture_output=True,
            text=True,
        )

        if result.returncode != 0:
            print("\n  Нет relay процессов")
            return

        pids = [int(p) for p in result.stdout.strip().split("\n") if p.strip()]
        print(f"\n  Hook relay PIDs: {pids}")

        assert len(pids) <= 1, (
            f"ДУБЛИКАТ: {len(pids)} relay процессов ({pids}). "
            f"Должен быть ровно 1. Нужно: kill {' '.join(str(p) for p in pids[1:])}"
        )

    def test_total_claude_flow_memory(self):
        """Суммарное потребление памяти всеми claude-flow процессами."""
        result = subprocess.run(
            ["pgrep", "-f", "claude-flow|hook-relay|@claude-flow"],
            capture_output=True,
            text=True,
        )

        if result.returncode != 0:
            print("\n  Нет claude-flow процессов")
            return

        pids = result.stdout.strip().split("\n")
        total_mb = 0

        for pid_str in pids:
            pid = pid_str.strip()
            if not pid:
                continue
            ps = subprocess.run(
                ["ps", "-p", pid, "-o", "rss=,comm="],
                capture_output=True,
                text=True,
            )
            if ps.returncode == 0:
                parts = ps.stdout.strip().split(None, 1)
                if parts:
                    rss_kb = int(parts[0])
                    comm = parts[1] if len(parts) > 1 else "?"
                    rss_mb = rss_kb / 1024
                    total_mb += rss_mb
                    print(f"  PID {pid}: {rss_mb:.0f}MB ({comm})")

        print(f"\n  Total claude-flow memory: {total_mb:.0f}MB")
        assert total_mb < 500, (
            f"Claude-flow потребляет {total_mb:.0f}MB > 500MB — утечка или zombies"
        )


# --- Watchdog ---


class TestWatchdogFunctionality:
    """Тесты watchdog скрипта."""

    def test_watchdog_check_runs(self, timer):
        """watchdog check завершается быстро и без ошибок."""
        t = timer()
        with t:
            result = subprocess.run(
                ["bash", str(HELPERS_DIR / "daemon-watchdog.sh"), "check"],
                capture_output=True,
                text=True,
                timeout=10,
                cwd=str(PROJECT_ROOT),
            )

        print(f"\n  Watchdog check: {t.elapsed_ms:.0f}ms, rc={result.returncode}")
        print(f"  stdout: {result.stdout[:200]}")
        assert result.returncode == 0, f"Watchdog check failed: {result.stderr}"
        assert t.elapsed_ms < 2000, f"Watchdog {t.elapsed_ms:.0f}ms > 2s"

    def test_watchdog_status_runs(self, timer):
        """watchdog status выводит корректный отчёт."""
        t = timer()
        with t:
            result = subprocess.run(
                ["bash", str(HELPERS_DIR / "daemon-watchdog.sh"), "status"],
                capture_output=True,
                text=True,
                timeout=10,
                cwd=str(PROJECT_ROOT),
            )

        print(f"\n  Watchdog status ({t.elapsed_ms:.0f}ms):")
        print(f"  {result.stdout[:500]}")
        assert result.returncode == 0
        assert "Claude Flow Watchdog" in result.stdout


# --- SessionStart overhead ---


class TestSessionStartOverhead:
    """Анализ overhead при старте сессии."""

    def test_relay_start_when_already_running(self, timer):
        """Если relay уже запущен — watchdog start мгновенный."""
        if not Path(SOCKET_PATH).exists():
            pytest.skip("Relay не запущен")

        t = timer()
        with t:
            result = subprocess.run(
                ["bash", str(HELPERS_DIR / "daemon-watchdog.sh"), "start"],
                capture_output=True,
                text=True,
                timeout=10,
                cwd=str(PROJECT_ROOT),
            )

        print(f"\n  Relay already-running check: {t.elapsed_ms:.0f}ms")
        print(f"  Output: {result.stdout[:200]}")

        assert t.elapsed_ms < 500, (
            f"watchdog start при работающем relay занял {t.elapsed_ms:.0f}ms > 500ms"
        )

    def test_full_session_start_overhead(self, timer):
        """Полный overhead SessionStart хуков (2 шага)."""
        steps = [
            ("watchdog start", ["bash", str(HELPERS_DIR / "daemon-watchdog.sh"), "start"]),
            ("session-restore", ["bash", str(HELPERS_DIR / "cf-hook.sh"), "hooks", "session-restore"]),
        ]

        total_ms = 0
        for name, cmd in steps:
            t = timer()
            try:
                with t:
                    subprocess.run(
                        cmd,
                        capture_output=True,
                        text=True,
                        timeout=15,
                        cwd=str(PROJECT_ROOT),
                    )
                total_ms += t.elapsed_ms
                print(f"  {name}: {t.elapsed_ms:.0f}ms")
            except subprocess.TimeoutExpired:
                print(f"  {name}: TIMEOUT (>15s)")
                total_ms += 15000

        print(f"\n  Total SessionStart overhead: {total_ms:.0f}ms")
        assert total_ms < 10000, f"SessionStart {total_ms:.0f}ms > 10s — критично!"


# --- Log analysis ---


class TestLogAnalysis:
    """Анализ логов для выявления проблем."""

    def test_no_repeated_errors_in_log(self):
        """В логе нет повторяющихся ошибок (> 5 одинаковых за сессию)."""
        if not Path(LOG_FILE).exists():
            pytest.skip("Лог файл не существует")

        log_text = Path(LOG_FILE).read_text()
        error_lines = [line for line in log_text.splitlines() if "ERROR" in line.upper()]

        error_patterns: dict[str, int] = {}
        for line in error_lines:
            clean = re.sub(r"\[[\dT:.Z-]+\]", "", line).strip()
            error_patterns[clean] = error_patterns.get(clean, 0) + 1

        repeated = {k: v for k, v in error_patterns.items() if v > 5}
        print(f"\n  Total error lines: {len(error_lines)}")
        print(f"  Unique patterns: {len(error_patterns)}")

        if repeated:
            msg = "Повторяющиеся ошибки (>5 раз):\n"
            for pattern, count in sorted(repeated.items(), key=lambda x: -x[1]):
                msg += f"  [{count}x] {pattern[:100]}\n"
            pytest.fail(msg)

    def test_eaddrinuse_not_present(self):
        """В логе нет ошибок EADDRINUSE (race condition при старте relay)."""
        if not Path(LOG_FILE).exists():
            pytest.skip("Лог файл не существует")

        log_text = Path(LOG_FILE).read_text()
        eaddrinuse_count = log_text.count("EADDRINUSE")

        print(f"\n  EADDRINUSE в логе: {eaddrinuse_count}")
        if eaddrinuse_count > 0:
            lines = [l for l in log_text.splitlines() if "EADDRINUSE" in l]
            for l in lines[-3:]:
                print(f"    {l[:120]}")
            pytest.fail(
                f"EADDRINUSE обнаружен {eaddrinuse_count} раз — "
                f"race condition при старте relay!"
            )

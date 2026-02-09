"""Тесты эффективности spawn-системы — комплексный аудит.

Собирает метрики БЕЗ LLM и генерирует отчёт эффективности:
- Соотношение overhead/полезная работа
- ROI hook relay vs прямой npx
- Утилизация ресурсов
- Рекомендации по оптимизации (автоматически на основе метрик)
"""

import json
import os
import re
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

import pytest

from .conftest import (
    CLAUDE_FLOW_DIR,
    DAEMON_STATE_FILES,
    HELPERS_DIR,
    LOG_FILE,
    PID_FILE,
    PROJECT_ROOT,
    SOCKET_PATH,
    Timer,
    call_cf_hook,
    read_daemon_state,
    send_socket_request,
)


@dataclass
class EfficiencyReport:
    """Отчёт эффективности spawn-системы."""

    # Latency
    relay_latency_ms: float = 0
    npx_latency_ms: float = 0
    relay_speedup: float = 0

    # Ресурсы
    total_memory_mb: float = 0
    relay_memory_mb: float = 0
    zombie_count: int = 0
    orphan_count: int = 0
    duplicate_count: int = 0

    # Утилизация
    hooks_called_total: int = 0
    hooks_per_hour: float = 0
    workers_executed: int = 0
    memory_entries: int = 0
    memory_patterns: int = 0

    # Проблемы
    issues: list[str] = field(default_factory=list)
    recommendations: list[str] = field(default_factory=list)

    # Оценка
    efficiency_score: float = 0  # 0-100

    def calculate_score(self):
        """Вычислить оценку эффективности 0-100."""
        score = 100.0

        if self.zombie_count > 0:
            score -= 20 * self.zombie_count
        if self.orphan_count > 0:
            score -= 15 * self.orphan_count
        if self.duplicate_count > 0:
            score -= 10 * self.duplicate_count
        if self.relay_latency_ms > 500:
            score -= 15
        elif self.relay_latency_ms > 200:
            score -= 5
        if self.total_memory_mb > 500:
            score -= 20
        elif self.total_memory_mb > 300:
            score -= 10
        if self.workers_executed == 0:
            score -= 15
        if self.memory_patterns == 0:
            score -= 10
        if self.hooks_per_hour < 1:
            score -= 5

        if self.relay_speedup > 5:
            score += 5
        if self.relay_latency_ms < 50:
            score += 10

        self.efficiency_score = max(0, min(100, score))

    def to_text(self) -> str:
        """Текстовый отчёт."""
        self.calculate_score()

        lines = [
            "=" * 60,
            "  ОТЧЁТ ЭФФЕКТИВНОСТИ SPAWN-СИСТЕМЫ",
            "=" * 60,
            "",
            f"  ОЦЕНКА: {self.efficiency_score:.0f}/100",
            "",
            "--- Latency ---",
            f"  Relay socket:   {self.relay_latency_ms:.0f}ms",
            f"  npx fallback:   {self.npx_latency_ms:.0f}ms",
            f"  Speedup:        {self.relay_speedup:.1f}x",
            "",
            "--- Ресурсы ---",
            f"  Total memory:   {self.total_memory_mb:.0f}MB",
            f"  Relay memory:   {self.relay_memory_mb:.0f}MB",
            f"  Zombie:         {self.zombie_count}",
            f"  Orphan:         {self.orphan_count}",
            f"  Duplicate:      {self.duplicate_count}",
            "",
            "--- Утилизация ---",
            f"  Hooks total:    {self.hooks_called_total}",
            f"  Hooks/hour:     {self.hooks_per_hour:.1f}",
            f"  Workers done:   {self.workers_executed}",
            f"  Memory entries: {self.memory_entries}",
            f"  Patterns:       {self.memory_patterns}",
            "",
        ]

        if self.issues:
            lines.append("--- ПРОБЛЕМЫ ---")
            for issue in self.issues:
                lines.append(f"  [!] {issue}")
            lines.append("")

        if self.recommendations:
            lines.append("--- РЕКОМЕНДАЦИИ ---")
            for i, rec in enumerate(self.recommendations, 1):
                lines.append(f"  {i}. {rec}")
            lines.append("")

        lines.append("=" * 60)
        return "\n".join(lines)


class TestSpawnEfficiencyAudit:
    """Комплексный аудит эффективности — собирает все метрики в один отчёт."""

    def test_full_efficiency_audit(self, timer):
        """Комплексный аудит: собрать все метрики и вычислить оценку."""
        report = EfficiencyReport()

        # 1. Latency relay
        if Path(SOCKET_PATH).exists():
            t = timer()
            try:
                with t:
                    send_socket_request(["hooks", "statusline", "--json"])
                report.relay_latency_ms = t.elapsed_ms
            except Exception:
                report.relay_latency_ms = -1
                report.issues.append("Hook relay не отвечает на socket запросы")

        # 2. Latency npx
        t_npx = timer()
        try:
            with t_npx:
                subprocess.run(
                    ["npx", "@claude-flow/cli@latest", "hooks", "statusline", "--json"],
                    capture_output=True,
                    timeout=15,
                    cwd=str(PROJECT_ROOT),
                )
            report.npx_latency_ms = t_npx.elapsed_ms
        except (subprocess.TimeoutExpired, FileNotFoundError):
            report.npx_latency_ms = 15000

        if report.relay_latency_ms > 0 and report.npx_latency_ms > 0:
            report.relay_speedup = report.npx_latency_ms / report.relay_latency_ms

        # 3. Процессы и память
        cf_pids = _get_claude_flow_pids()
        for pid_info in cf_pids:
            report.total_memory_mb += pid_info["rss_mb"]

        if Path(PID_FILE).exists():
            try:
                pid = Path(PID_FILE).read_text().strip()
                rss = _get_pid_rss(pid)
                report.relay_memory_mb = rss
            except Exception:
                pass

        # 4. Zombies
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
                        report.zombie_count += 1
                        report.issues.append(
                            f"Zombie: {state_path.name} running=true, PID {pid} мёртв"
                        )

        # 5. Duplicate relay
        relay_pids = _pgrep("hook-relay")
        if len(relay_pids) > 1:
            report.duplicate_count = len(relay_pids) - 1
            report.issues.append(f"{len(relay_pids)} relay процессов (должен быть 1)")

        # 6. Workers
        if DAEMON_STATE_FILES:
            root_state = read_daemon_state(DAEMON_STATE_FILES[0])
            workers = root_state.get("workers", root_state.get("config", {}).get("workers", {}))
            if isinstance(workers, dict):
                for name, metrics in workers.items():
                    if isinstance(metrics, dict):
                        report.workers_executed += metrics.get("runCount", 0)

        if report.workers_executed == 0:
            report.issues.append("Workers: 0 задач выполнено — daemon не работает")
            report.recommendations.append(
                "Убить zombie daemon процессы и запускать workers on-demand через CLI"
            )

        # 7. Hook log analysis
        if Path(LOG_FILE).exists():
            log_text = Path(LOG_FILE).read_text()
            hook_lines = [l for l in log_text.splitlines() if "HOOK:" in l]
            report.hooks_called_total = len(hook_lines)

            if hook_lines:
                timestamps = []
                for line in hook_lines:
                    match = re.search(r"\[(\d{4}-\d{2}-\d{2}T[\d:.]+Z?)\]", line)
                    if match:
                        timestamps.append(match.group(1))
                if len(timestamps) >= 2:
                    hours_set = set(t[:13] for t in timestamps)
                    if hours_set:
                        report.hooks_per_hour = len(hook_lines) / max(len(hours_set), 1)

        # 8. Memory system
        try:
            result = call_cf_hook(["memory", "stats"], timeout=10)
            if result.returncode == 0:
                try:
                    stats = json.loads(result.stdout)
                    report.memory_entries = stats.get("totalEntries", 0)
                    namespaces = stats.get("namespaces", {})
                    report.memory_patterns = namespaces.get("patterns", {}).get("count", 0)
                except (json.JSONDecodeError, AttributeError):
                    pass
        except Exception:
            pass

        if report.memory_patterns == 0:
            report.issues.append("Memory patterns: 0 — auto-learning не работает")
            report.recommendations.append(
                "Включить auto-learning: memory store после каждой успешной фичи"
            )

        # 9. Рекомендации
        if report.relay_latency_ms > 200:
            report.recommendations.append(
                f"Relay latency {report.relay_latency_ms:.0f}ms — "
                f"нужен persistent CLI process (цель: <50ms)"
            )
        if report.total_memory_mb > 300:
            report.recommendations.append(
                f"Потребление {report.total_memory_mb:.0f}MB — "
                f"убить zombie/orphan процессы"
            )
        if report.relay_speedup < 3:
            report.recommendations.append(
                f"Relay speedup только {report.relay_speedup:.1f}x — "
                f"overhead relay не оправдан при малом числе вызовов"
            )

        # Отчёт
        text = report.to_text()
        print(f"\n{text}")

        # Сохраняем
        report_path = CLAUDE_FLOW_DIR / "efficiency-report.json"
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_data = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "score": report.efficiency_score,
            "latency": {
                "relay_ms": report.relay_latency_ms,
                "npx_ms": report.npx_latency_ms,
                "speedup": report.relay_speedup,
            },
            "resources": {
                "total_memory_mb": report.total_memory_mb,
                "relay_memory_mb": report.relay_memory_mb,
                "zombies": report.zombie_count,
                "orphans": report.orphan_count,
                "duplicates": report.duplicate_count,
            },
            "utilization": {
                "hooks_total": report.hooks_called_total,
                "hooks_per_hour": report.hooks_per_hour,
                "workers_executed": report.workers_executed,
                "memory_entries": report.memory_entries,
                "memory_patterns": report.memory_patterns,
            },
            "issues": report.issues,
            "recommendations": report.recommendations,
        }
        with open(report_path, "w") as f:
            json.dump(report_data, f, indent=2, ensure_ascii=False)

        print(f"\n  Report saved: {report_path}")


class TestOverheadRatio:
    """Анализ соотношения overhead к полезной работе."""

    def test_relay_overhead_per_call(self, relay_running, timer):
        """Overhead relay на один вызов vs полезная работа CLI."""
        t_full = timer()
        with t_full:
            result = send_socket_request(["hooks", "statusline", "--json"])

        latencies = []
        for _ in range(5):
            t = timer()
            with t:
                send_socket_request(["hooks", "statusline", "--json"])
            latencies.append(t.elapsed_ms)

        avg = sum(latencies) / len(latencies)
        min_lat = min(latencies)
        estimated_overhead_ms = avg - min_lat
        overhead_pct = (estimated_overhead_ms / avg * 100) if avg > 0 else 0

        print(f"\n  Average latency:    {avg:.0f}ms")
        print(f"  Minimum latency:    {min_lat:.0f}ms")
        print(f"  Estimated overhead: {estimated_overhead_ms:.0f}ms ({overhead_pct:.0f}%)")
        print(f"  Latencies: {[f'{l:.0f}' for l in latencies]}")

    def test_relay_roi_calculation(self, relay_running, timer):
        """ROI: экономит ли relay время по сравнению с npx?"""
        t_relay = timer()
        with t_relay:
            send_socket_request(["hooks", "statusline", "--json"])

        t_npx = timer()
        try:
            with t_npx:
                subprocess.run(
                    ["npx", "@claude-flow/cli@latest", "hooks", "statusline", "--json"],
                    capture_output=True,
                    timeout=15,
                    cwd=str(PROJECT_ROOT),
                )
            npx_ms = t_npx.elapsed_ms
        except (subprocess.TimeoutExpired, FileNotFoundError):
            npx_ms = 2000

        calls_in_log = 0
        if Path(LOG_FILE).exists():
            log_text = Path(LOG_FILE).read_text()
            calls_in_log = log_text.count("HOOK:")

        time_saved_per_call = npx_ms - t_relay.elapsed_ms
        estimated_calls_per_session = max(calls_in_log, 10)
        total_saved_ms = time_saved_per_call * estimated_calls_per_session

        relay_mb = 0
        if Path(PID_FILE).exists():
            pid = Path(PID_FILE).read_text().strip()
            relay_mb = _get_pid_rss(pid)

        print(f"\n  === ROI Анализ ===")
        print(f"  Relay latency:       {t_relay.elapsed_ms:.0f}ms")
        print(f"  npx latency:         {npx_ms:.0f}ms")
        print(f"  Экономия/вызов:      {time_saved_per_call:.0f}ms")
        print(f"  Вызовов за сессию:   ~{estimated_calls_per_session}")
        print(f"  Экономия суммарно:   {total_saved_ms / 1000:.1f}s")
        print(f"  Relay memory:        {relay_mb:.0f}MB")
        print(f"  Вердикт:             {'ОПРАВДАН' if total_saved_ms > 5000 else 'НЕ ОПРАВДАН'}")


class TestResourceUtilization:
    """Утилизация ресурсов spawn-системы."""

    def test_active_vs_idle_processes(self):
        """Соотношение активных и простаивающих процессов."""
        cf_pids = _get_claude_flow_pids()

        active = 0
        idle = 0
        for info in cf_pids:
            if info.get("cpu_pct", 0) > 0.1:
                active += 1
            else:
                idle += 1

        total = active + idle
        utilization = (active / total * 100) if total > 0 else 0

        print(f"\n  Claude-flow процессы: {total}")
        print(f"  Active (CPU > 0.1%): {active}")
        print(f"  Idle:                {idle}")
        print(f"  Utilization:         {utilization:.0f}%")

    def test_file_descriptor_leak(self):
        """Проверка утечки file descriptors relay процессом."""
        if not Path(PID_FILE).exists():
            pytest.skip("PID файл не существует")

        pid = Path(PID_FILE).read_text().strip()
        try:
            result = subprocess.run(
                ["lsof", "-p", pid],
                capture_output=True,
                text=True,
            )
            if result.returncode == 0:
                fd_count = len(result.stdout.splitlines()) - 1
                print(f"\n  Relay PID {pid}: {fd_count} open file descriptors")
                assert fd_count < 200, f"FD leak: {fd_count} open FDs > 200"
            else:
                pytest.skip(f"lsof не работает для PID {pid}")
        except FileNotFoundError:
            pytest.skip("lsof не найден")

    def test_disk_usage(self):
        """Дисковое пространство claude-flow файлов."""
        paths_to_check = [
            (CLAUDE_FLOW_DIR, ".claude-flow/"),
            (PROJECT_ROOT / ".claude" / "helpers", ".claude/helpers/"),
            (Path("/tmp"), "/tmp/claude-flow-*"),
        ]

        total_kb = 0
        for dir_path, label in paths_to_check:
            if not dir_path.exists():
                continue

            if label.startswith("/tmp"):
                result = subprocess.run(
                    ["bash", "-c", "du -sk /tmp/claude-flow-* 2>/dev/null | awk '{s+=$1}END{print s+0}'"],
                    capture_output=True,
                    text=True,
                )
                size_kb = int(result.stdout.strip() or "0")
            else:
                result = subprocess.run(
                    ["du", "-sk", str(dir_path)],
                    capture_output=True,
                    text=True,
                )
                size_kb = int(result.stdout.split()[0]) if result.returncode == 0 else 0

            total_kb += size_kb
            print(f"  {label}: {size_kb}KB ({size_kb / 1024:.1f}MB)")

        print(f"\n  Total disk: {total_kb}KB ({total_kb / 1024:.1f}MB)")
        assert total_kb < 102400, f"Disk usage {total_kb / 1024:.0f}MB > 100MB"


# --- Helpers ---


def _get_claude_flow_pids() -> list[dict]:
    """Получить все claude-flow процессы с метриками."""
    result = subprocess.run(
        ["bash", "-c", "ps aux | grep -E 'claude-flow|hook-relay|@claude-flow' | grep -v grep"],
        capture_output=True,
        text=True,
    )

    pids = []
    for line in result.stdout.strip().splitlines():
        if not line:
            continue
        parts = line.split()
        if len(parts) >= 11:
            pids.append({
                "pid": parts[1],
                "cpu_pct": float(parts[2]),
                "rss_mb": float(parts[5]) / 1024 if parts[5].isdigit() else 0,
                "command": " ".join(parts[10:])[:80],
            })
    return pids


def _get_pid_rss(pid: str) -> float:
    """Получить RSS процесса в MB."""
    result = subprocess.run(
        ["ps", "-p", pid, "-o", "rss="],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0 and result.stdout.strip():
        return int(result.stdout.strip()) / 1024
    return 0


def _pgrep(pattern: str) -> list[int]:
    """pgrep по паттерну."""
    result = subprocess.run(
        ["pgrep", "-f", pattern],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return []
    return [int(p) for p in result.stdout.strip().split("\n") if p.strip()]

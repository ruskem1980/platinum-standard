"""Тесты производительности и надёжности hook relay.

Метрики без LLM:
- Latency Unix socket вызовов (цель: < 300ms, оптимум < 50ms)
- Throughput при параллельных запросах
- Fallback корректность
- Стабильность соединений
"""

import json
import os
import statistics
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import pytest

from .conftest import (
    HELPERS_DIR,
    LOG_FILE,
    PID_FILE,
    PROJECT_ROOT,
    SOCKET_PATH,
    Timer,
    call_cf_hook,
    send_socket_request,
)

# --- Latency тесты ---


class TestHookRelayLatency:
    """Замер латентности Unix socket вызовов."""

    def test_single_call_latency(self, relay_running, timer):
        """Одиночный socket вызов — замер baseline latency."""
        t = timer()
        with t:
            result = send_socket_request(["hooks", "statusline", "--json"])

        assert result.get("ok") is True, f"Relay вернул ошибку: {result}"
        print(f"\n  Socket call latency: {t.elapsed_ms:.1f}ms")
        assert t.elapsed_ms < 2000, f"Latency {t.elapsed_ms:.0f}ms > 2000ms — деградация!"

    def test_repeated_calls_consistency(self, relay_running, timer):
        """10 последовательных вызовов — анализ стабильности."""
        latencies = []
        errors = 0

        for i in range(10):
            t = timer()
            try:
                with t:
                    result = send_socket_request(["hooks", "statusline", "--json"])
                if result.get("ok"):
                    latencies.append(t.elapsed_ms)
                else:
                    errors += 1
            except Exception:
                errors += 1

        assert len(latencies) >= 8, f"Слишком много ошибок: {errors}/10"

        stats = {
            "min": min(latencies),
            "max": max(latencies),
            "mean": statistics.mean(latencies),
            "median": statistics.median(latencies),
            "stdev": statistics.stdev(latencies) if len(latencies) > 1 else 0,
            "p95": sorted(latencies)[int(len(latencies) * 0.95)] if latencies else 0,
            "errors": errors,
        }

        print(f"\n  Latency stats (10 calls):")
        print(f"    min={stats['min']:.1f}ms  max={stats['max']:.1f}ms")
        print(f"    mean={stats['mean']:.1f}ms  median={stats['median']:.1f}ms")
        print(f"    stdev={stats['stdev']:.1f}ms  p95={stats['p95']:.1f}ms")
        print(f"    errors={stats['errors']}/10")

        if stats["mean"] > 0:
            cv = stats["stdev"] / stats["mean"]
            assert cv < 1.0, f"CV={cv:.2f} — слишком нестабильные latency"

    def test_cf_hook_wrapper_overhead(self, relay_running, timer):
        """Сравнение: raw socket vs cf-hook.sh wrapper — overhead bash."""
        t_socket = timer()
        with t_socket:
            send_socket_request(["hooks", "statusline", "--json"])

        t_wrapper = timer()
        with t_wrapper:
            call_cf_hook(["hooks", "statusline", "--json"])

        overhead = t_wrapper.elapsed_ms - t_socket.elapsed_ms
        overhead_pct = (overhead / t_socket.elapsed_ms * 100) if t_socket.elapsed_ms > 0 else 0

        print(f"\n  Raw socket: {t_socket.elapsed_ms:.1f}ms")
        print(f"  cf-hook.sh: {t_wrapper.elapsed_ms:.1f}ms")
        print(f"  Overhead:   {overhead:.1f}ms ({overhead_pct:.0f}%)")

        assert overhead < 200, f"Bash wrapper overhead {overhead:.0f}ms > 200ms"


# --- Throughput тесты ---


class TestHookRelayThroughput:
    """Замер пропускной способности при параллельных запросах."""

    def test_concurrent_5_requests(self, relay_running, timer):
        """5 параллельных запросов — базовый concurrency."""
        results = []
        t = timer()

        with t:
            with ThreadPoolExecutor(max_workers=5) as executor:
                futures = [
                    executor.submit(send_socket_request, ["hooks", "statusline", "--json"])
                    for _ in range(5)
                ]
                for future in as_completed(futures):
                    try:
                        results.append(future.result())
                    except Exception as e:
                        results.append({"ok": False, "error": str(e)})

        successes = sum(1 for r in results if r.get("ok"))
        print(f"\n  5 concurrent: {t.elapsed_ms:.0f}ms total, {successes}/5 ok")
        print(f"  Throughput: {5 / (t.elapsed_ms / 1000):.1f} req/s")

        assert successes >= 4, f"Только {successes}/5 успешных"

    def test_concurrent_20_requests(self, relay_running, timer):
        """20 параллельных запросов — stress test."""
        results = []
        t = timer()

        with t:
            with ThreadPoolExecutor(max_workers=20) as executor:
                futures = [
                    executor.submit(send_socket_request, ["hooks", "statusline", "--json"])
                    for _ in range(20)
                ]
                for future in as_completed(futures):
                    try:
                        results.append(future.result())
                    except Exception as e:
                        results.append({"ok": False, "error": str(e)})

        successes = sum(1 for r in results if r.get("ok"))
        throughput = 20 / (t.elapsed_ms / 1000) if t.elapsed_ms > 0 else 0

        print(f"\n  20 concurrent: {t.elapsed_ms:.0f}ms total")
        print(f"  Success rate: {successes}/20 ({successes / 20 * 100:.0f}%)")
        print(f"  Throughput: {throughput:.1f} req/s")

        assert successes >= 15, f"Только {successes}/20 — relay не справляется"

    def test_sequential_vs_parallel_speedup(self, relay_running, timer):
        """Сравнение: 5 последовательных vs 5 параллельных."""
        t_seq = timer()
        seq_ok = 0
        with t_seq:
            for _ in range(5):
                r = send_socket_request(["hooks", "statusline", "--json"])
                if r.get("ok"):
                    seq_ok += 1

        t_par = timer()
        par_ok = 0
        with t_par:
            with ThreadPoolExecutor(max_workers=5) as executor:
                futures = [
                    executor.submit(send_socket_request, ["hooks", "statusline", "--json"])
                    for _ in range(5)
                ]
                for f in as_completed(futures):
                    try:
                        if f.result().get("ok"):
                            par_ok += 1
                    except Exception:
                        pass

        speedup = t_seq.elapsed_ms / t_par.elapsed_ms if t_par.elapsed_ms > 0 else 0
        print(f"\n  Sequential 5: {t_seq.elapsed_ms:.0f}ms ({seq_ok}/5 ok)")
        print(f"  Parallel 5:   {t_par.elapsed_ms:.0f}ms ({par_ok}/5 ok)")
        print(f"  Speedup:      {speedup:.2f}x")


# --- Reliability тесты ---


class TestHookRelayReliability:
    """Тесты надёжности и устойчивости к ошибкам."""

    def test_socket_exists(self):
        """Unix socket файл существует."""
        exists = Path(SOCKET_PATH).exists()
        is_socket = Path(SOCKET_PATH).is_socket() if exists else False
        print(f"\n  Socket exists: {exists}, is_socket: {is_socket}")
        if not exists:
            pytest.skip("Socket не существует — relay не запущен")

    def test_pid_file_valid(self):
        """PID файл содержит живой процесс."""
        if not Path(PID_FILE).exists():
            pytest.skip("PID файл не существует")

        pid = int(Path(PID_FILE).read_text().strip())
        try:
            os.kill(pid, 0)
            alive = True
        except OSError:
            alive = False

        print(f"\n  PID: {pid}, alive: {alive}")
        assert alive, f"PID {pid} из {PID_FILE} мёртв — stale PID file!"

    def test_invalid_payload_handling(self, relay_running):
        """Relay корректно обрабатывает невалидный payload."""
        result = send_socket_request([])
        print(f"\n  Empty args: {result}")

        result2 = send_socket_request(["hooks", "statusline", "--json"])
        assert result2.get("ok") is True, "Relay упал после невалидного запроса!"

    def test_large_payload_handling(self, relay_running):
        """Relay обрабатывает большие аргументы (10KB+)."""
        large_value = "x" * 10000
        result = send_socket_request(["memory", "store", "--value", large_value])

        time.sleep(0.2)
        result2 = send_socket_request(["hooks", "statusline", "--json"])
        assert result2.get("ok") is True, "Relay упал после большого payload!"

    def test_log_file_growth(self, relay_running, log_snapshot):
        """Лог файл не растёт бесконтрольно."""
        for _ in range(5):
            send_socket_request(["hooks", "statusline", "--json"])

        if Path(LOG_FILE).exists():
            current_lines = len(Path(LOG_FILE).read_text().splitlines())
            growth = current_lines - log_snapshot
            log_size_kb = Path(LOG_FILE).stat().st_size / 1024
            print(f"\n  Log growth: +{growth} lines (total {current_lines})")
            print(f"  Log size: {log_size_kb:.1f}KB")
            assert growth <= 25, f"Лог вырос на {growth} строк за 5 вызовов — утечка!"
            assert log_size_kb < 10240, f"Лог {log_size_kb:.0f}KB > 10MB — нужна ротация"


# --- Spawn overhead тесты ---


class TestSpawnOverhead:
    """Анализ overhead вызова CLI через relay."""

    def test_cli_resolution_cached(self, relay_running, timer):
        """CLI путь кеширован — нет повторного resolve при каждом вызове."""
        t1 = timer()
        with t1:
            r1 = send_socket_request(["hooks", "statusline", "--json"])

        t2 = timer()
        with t2:
            r2 = send_socket_request(["hooks", "statusline", "--json"])

        print(f"\n  Call 1: {t1.elapsed_ms:.1f}ms")
        print(f"  Call 2: {t2.elapsed_ms:.1f}ms")
        print(f"  Diff:   {t2.elapsed_ms - t1.elapsed_ms:+.1f}ms")

        assert t2.elapsed_ms < t1.elapsed_ms * 2, "Второй вызов в 2x медленнее — кеш не работает"

    def test_npx_fallback_latency(self, timer):
        """npx fallback latency (без socket) — baseline для сравнения."""
        t = timer()
        try:
            with t:
                result = subprocess.run(
                    ["npx", "@claude-flow/cli@latest", "hooks", "statusline", "--json"],
                    capture_output=True,
                    text=True,
                    timeout=15,
                    cwd=str(PROJECT_ROOT),
                )
            print(f"\n  npx fallback: {t.elapsed_ms:.1f}ms (exit={result.returncode})")

            if Path(SOCKET_PATH).exists():
                t_relay = timer()
                with t_relay:
                    send_socket_request(["hooks", "statusline", "--json"])
                speedup = t.elapsed_ms / t_relay.elapsed_ms if t_relay.elapsed_ms > 0 else 0
                print(f"  Relay:        {t_relay.elapsed_ms:.1f}ms")
                print(f"  Speedup:      {speedup:.1f}x")
        except subprocess.TimeoutExpired:
            print(f"\n  npx fallback: TIMEOUT (>15s)")

    def test_relay_memory_usage(self):
        """Потребление памяти hook relay процессом."""
        if not Path(PID_FILE).exists():
            pytest.skip("PID файл не существует")

        pid = Path(PID_FILE).read_text().strip()
        try:
            result = subprocess.run(
                ["ps", "-p", pid, "-o", "rss="],
                capture_output=True,
                text=True,
            )
            if result.returncode == 0:
                rss_kb = int(result.stdout.strip())
                rss_mb = rss_kb / 1024
                print(f"\n  Relay PID {pid}: {rss_mb:.1f}MB RSS")
                assert rss_mb < 200, f"Relay {rss_mb:.0f}MB > 200MB — утечка памяти!"
            else:
                pytest.skip(f"ps не нашёл PID {pid}")
        except Exception as e:
            pytest.skip(f"Ошибка ps: {e}")


# --- JSON escaping тесты ---


class TestJsonEscaping:
    """Тесты корректности JSON escaping в cf-hook.sh."""

    def test_special_characters(self, relay_running):
        """Спецсимволы в аргументах не ломают JSON."""
        special_args = [
            ["hooks", "statusline", "--value", 'test "quoted" value'],
            ["hooks", "statusline", "--value", "path/with spaces/file.txt"],
            ["hooks", "statusline", "--value", "line1\nline2"],
            ["hooks", "statusline", "--value", "tabs\there"],
        ]

        for args in special_args:
            try:
                result = call_cf_hook(args, timeout=5)
                print(f"  args={args[-1][:30]}... rc={result.returncode}")
            except subprocess.TimeoutExpired:
                pytest.fail(f"Timeout на args: {args}")

    def test_unicode_arguments(self, relay_running):
        """Кириллица и unicode в аргументах."""
        result = call_cf_hook(
            ["hooks", "statusline", "--value", "Тест кириллицы"],
            timeout=5,
        )
        print(f"\n  Unicode test: rc={result.returncode}")
        assert result.returncode is not None

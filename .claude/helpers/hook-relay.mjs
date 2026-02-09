#!/usr/bin/env node
/**
 * Hook Relay Server v2 — persistent CLI process + lock file + /metrics endpoint.
 *
 * Оптимизации vs v1:
 *  1. Persistent CLI child — один long-running node процесс вместо spawn на каждый вызов
 *  2. Lock file — предотвращает EADDRINUSE при параллельном старте
 *  3. GET /metrics — агрегированные метрики вместо 6 JSON файлов
 *
 * Запуск: node .claude/helpers/hook-relay.mjs
 * API:
 *   POST /hook   { "args": ["hooks", "post-edit", "--file", "path"] }
 *   GET  /metrics
 *   GET  /health
 */

import http from 'http';
import { spawn } from 'child_process';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const SOCKET_PATH = '/tmp/claude-flow-hook-relay.sock';
const PID_FILE = '/tmp/claude-flow-hook-relay.pid';
const LOCK_FILE = '/tmp/claude-flow-hook-relay.lock';
const LOG_FILE = '/tmp/claude-flow-hooks.log';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = path.resolve(__dirname, '../..');

// Метрики
const metrics = {
  startedAt: new Date().toISOString(),
  totalCalls: 0,
  successCalls: 0,
  errorCalls: 0,
  totalLatencyMs: 0,
  persistentHits: 0,
  spawnFallbacks: 0,
};

let resolvedCliPath = null;
// Persistent CLI child process — один на все вызовы
let persistentCli = null;
let persistentReady = false;
let pendingRequests = new Map();
let requestCounter = 0;

function log(msg) {
  const line = `[${new Date().toISOString()}] [relay] ${msg}\n`;
  try { fs.appendFileSync(LOG_FILE, line); } catch {}
}

function resolveCliPath() {
  const HOME = process.env.HOME || '/tmp';
  const searchPaths = [
    path.join(PROJECT_ROOT, 'node_modules', '@claude-flow', 'cli', 'bin', 'cli.js'),
    path.join(PROJECT_ROOT, 'node_modules', '.bin', 'claude-flow'),
  ];

  const npxCacheDir = path.join(HOME, '.npm', '_npx');
  try {
    if (fs.existsSync(npxCacheDir)) {
      for (const hash of fs.readdirSync(npxCacheDir)) {
        searchPaths.push(path.join(npxCacheDir, hash, 'node_modules', '@claude-flow', 'cli', 'bin', 'cli.js'));
      }
    }
  } catch {}

  searchPaths.push(
    path.join(HOME, '.npm-global', 'lib', 'node_modules', '@claude-flow', 'cli', 'bin', 'cli.js'),
    '/usr/local/lib/node_modules/@claude-flow/cli/bin/cli.js',
  );

  for (const p of searchPaths) {
    if (fs.existsSync(p)) {
      log(`CLI найден: ${p}`);
      return p;
    }
  }

  log('CLI не найден, будет использоваться npx');
  return null;
}

// --- Lock file для предотвращения EADDRINUSE ---

function acquireLock() {
  try {
    // O_EXCL — атомарное создание, фейлит если файл уже есть
    const fd = fs.openSync(LOCK_FILE, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY);
    fs.writeSync(fd, String(process.pid));
    fs.closeSync(fd);
    return true;
  } catch {
    // Lock уже захвачен — проверяем жив ли владелец
    try {
      const ownerPid = parseInt(fs.readFileSync(LOCK_FILE, 'utf8').trim());
      if (ownerPid && ownerPid !== process.pid) {
        try {
          process.kill(ownerPid, 0); // проверка без убийства
          log(`Lock занят живым процессом PID ${ownerPid} — выходим`);
          return false;
        } catch {
          // Владелец мёртв — забираем lock
          log(`Stale lock от PID ${ownerPid} — перехватываем`);
          fs.writeFileSync(LOCK_FILE, String(process.pid));
          return true;
        }
      }
    } catch {
      // Не смогли прочитать lock — пробуем перезаписать
      fs.writeFileSync(LOCK_FILE, String(process.pid));
      return true;
    }
  }
  return false;
}

function releaseLock() {
  try { fs.unlinkSync(LOCK_FILE); } catch {}
}

// --- Persistent CLI process (JSON-RPC через stdin/stdout) ---

function startPersistentCli() {
  if (!resolvedCliPath) return;

  // Запускаем CLI в режиме JSON-RPC pipe
  persistentCli = spawn(process.execPath, [resolvedCliPath, 'mcp', 'pipe'], {
    cwd: PROJECT_ROOT,
    stdio: ['pipe', 'pipe', 'pipe'],
    env: { ...process.env, FORCE_COLOR: '0' },
  });

  let buffer = '';
  persistentCli.stdout.on('data', chunk => {
    buffer += chunk;
    // Парсим JSON-line ответы
    const lines = buffer.split('\n');
    buffer = lines.pop(); // последний неполный
    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        const resp = JSON.parse(line);
        if (resp._id && pendingRequests.has(resp._id)) {
          const { resolve } = pendingRequests.get(resp._id);
          pendingRequests.delete(resp._id);
          resolve(resp);
        }
      } catch {}
    }
  });

  persistentCli.stderr.on('data', d => {
    const msg = d.toString().trim();
    if (msg) log(`PERSISTENT STDERR: ${msg.slice(0, 200)}`);
  });

  persistentCli.on('close', code => {
    log(`Persistent CLI завершился (code=${code})`);
    persistentCli = null;
    persistentReady = false;
    // Реджектим все pending
    for (const [id, { reject }] of pendingRequests) {
      reject(new Error('CLI process exited'));
    }
    pendingRequests.clear();
  });

  persistentCli.on('error', err => {
    log(`Persistent CLI error: ${err.message}`);
    persistentCli = null;
    persistentReady = false;
  });

  persistentReady = true;
  log('Persistent CLI запущен (pipe mode)');
}

function callPersistentCli(args, timeout = 10000) {
  return new Promise((resolve, reject) => {
    if (!persistentCli || !persistentReady || !persistentCli.stdin.writable) {
      reject(new Error('persistent CLI unavailable'));
      return;
    }

    const id = `req_${++requestCounter}`;
    const timer = setTimeout(() => {
      pendingRequests.delete(id);
      reject(new Error('timeout'));
    }, timeout);

    pendingRequests.set(id, {
      resolve: (resp) => { clearTimeout(timer); resolve(resp); },
      reject: (err) => { clearTimeout(timer); reject(err); },
    });

    try {
      persistentCli.stdin.write(JSON.stringify({ _id: id, args }) + '\n');
    } catch (e) {
      clearTimeout(timer);
      pendingRequests.delete(id);
      reject(e);
    }
  });
}

// --- Fallback: spawn на каждый вызов (старый метод) ---

function callSpawnCli(args) {
  return new Promise((resolve, reject) => {
    let cmd, cmdArgs;
    if (resolvedCliPath) {
      cmd = process.execPath;
      cmdArgs = [resolvedCliPath, ...args];
    } else {
      cmd = 'npx';
      cmdArgs = ['@claude-flow/cli@latest', ...args];
    }

    const proc = spawn(cmd, cmdArgs, {
      cwd: PROJECT_ROOT,
      timeout: 10000,
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, FORCE_COLOR: '0' },
    });

    let stdout = '', stderr = '';
    proc.stdout.on('data', d => stdout += d);
    proc.stderr.on('data', d => stderr += d);
    proc.on('close', code => resolve({ ok: code === 0, stdout, stderr }));
    proc.on('error', reject);
  });
}

// --- HTTP handler ---

async function handleHook(req, res) {
  let body = '';
  req.on('data', chunk => body += chunk);
  req.on('end', async () => {
    const start = Date.now();
    metrics.totalCalls++;

    try {
      const { args } = JSON.parse(body);
      if (!Array.isArray(args) || args.length === 0) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end('{"error": "args must be non-empty array"}');
        return;
      }

      log(`HOOK: ${args.join(' ')}`);

      let result;
      // Пробуем persistent CLI, fallback на spawn
      if (persistentCli && persistentReady) {
        try {
          result = await callPersistentCli(args);
          metrics.persistentHits++;
        } catch {
          // Persistent не сработал — fallback
          result = await callSpawnCli(args);
          metrics.spawnFallbacks++;
        }
      } else {
        result = await callSpawnCli(args);
        metrics.spawnFallbacks++;
      }

      const latency = Date.now() - start;
      metrics.totalLatencyMs += latency;

      const ok = result.ok !== false;
      if (ok) metrics.successCalls++; else metrics.errorCalls++;

      if (!ok) log(`ERROR: ${(result.stderr || '').slice(0, 200)}`);

      res.writeHead(ok ? 200 : 500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        ok,
        stdout: result.stdout || '',
        stderr: result.stderr || '',
      }));

    } catch (e) {
      metrics.errorCalls++;
      log(`PARSE ERROR: ${e.message}`);
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: false, error: e.message }));
    }
  });
}

function handleMetrics(req, res) {
  const avgLatency = metrics.totalCalls > 0
    ? (metrics.totalLatencyMs / metrics.totalCalls).toFixed(1)
    : 0;

  const data = {
    ...metrics,
    avgLatencyMs: parseFloat(avgLatency),
    uptime: Math.floor((Date.now() - new Date(metrics.startedAt).getTime()) / 1000),
    persistentCliActive: !!(persistentCli && persistentReady),
    pendingRequests: pendingRequests.size,
    pid: process.pid,
    memoryMB: Math.round(process.memoryUsage().rss / 1024 / 1024),
  };

  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(data, null, 2));
}

function handleHealth(req, res) {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ ok: true, pid: process.pid }));
}

// --- Очистка сокета и lock проверка ---

if (!acquireLock()) {
  log('Другой relay уже работает — выходим без ошибки');
  process.exit(0);
}

// Удаляем stale socket если есть
try { fs.unlinkSync(SOCKET_PATH); } catch {}

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/metrics') {
    return handleMetrics(req, res);
  }
  if (req.method === 'GET' && req.url === '/health') {
    return handleHealth(req, res);
  }
  if (req.method !== 'POST') {
    res.writeHead(405);
    res.end('POST /hook, GET /metrics, GET /health');
    return;
  }
  handleHook(req, res);
});

server.listen(SOCKET_PATH, () => {
  fs.writeFileSync(PID_FILE, String(process.pid));
  fs.chmodSync(SOCKET_PATH, 0o666);
  log(`Hook relay v2 запущен (PID: ${process.pid}, socket: ${SOCKET_PATH})`);

  // Resolve CLI и запускаем persistent process
  resolvedCliPath = resolveCliPath();
  if (resolvedCliPath) {
    startPersistentCli();
  }
});

server.on('error', err => {
  log(`SERVER ERROR: ${err.message}`);
  releaseLock();
  process.exit(1);
});

// Graceful shutdown
function shutdown(signal) {
  log(`Завершение по сигналу ${signal}`);
  if (persistentCli) {
    try { persistentCli.kill(); } catch {}
  }
  server.close();
  try { fs.unlinkSync(SOCKET_PATH); } catch {}
  try { fs.unlinkSync(PID_FILE); } catch {}
  releaseLock();
  process.exit(0);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('uncaughtException', err => {
  log(`UNCAUGHT: ${err.message}`);
  shutdown('uncaughtException');
});

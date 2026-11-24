import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { atomicJson } from './usage.mjs';

const validCount = value => (Number.isSafeInteger(value) && value >= 0 ? value : null);

export function localDate(date = new Date()) {
  return [
    date.getFullYear(),
    String(date.getMonth() + 1).padStart(2, '0'),
    String(date.getDate()).padStart(2, '0')
  ].join('-');
}

function makeRecord(step, sessionId, previous) {
  if (!Number.isSafeInteger(step?.step_index) || step.step_index < 0 || step.status !== 'DONE') return null;
  if (typeof sessionId !== 'string' || !sessionId || sessionId.length > 256) return null;
  if (typeof step.created_at !== 'string' || !step.created_at.trim()) return null;
  const date = new Date(step.created_at);
  if (!Number.isFinite(date.getTime())) return null;
  const tokens = {
    input: previous?.tokens.input ?? validCount(step.input_tokens),
    cache: previous?.tokens.cache ?? validCount(step.cache_read_tokens),
    output: previous?.tokens.output ?? validCount(step.output_tokens)
  };
  if (Object.values(tokens).every(v => v === null)) return null;
  tokens.total = Object.values(tokens).every(v => v !== null)
    ? tokens.input + tokens.cache + tokens.output
    : null;
  if (!Number.isSafeInteger(tokens.total)) tokens.total = null;
  return {
    id: `${sessionId}:${step.step_index}`,
    sessionId,
    stepIndex: step.step_index,
    timestamp: previous?.timestamp || date.toISOString(),
    date: localDate(previous ? new Date(previous.timestamp) : date),
    tokens,
    status: 'DONE',
    kind: 'model-step'
  };
}

export class AntigravityLedgerScanner {
  constructor({ storagePath = null, appDataDir = null, now = () => new Date() } = {}) {
    this.storagePath = storagePath;
    this.appDataDir = appDataDir || path.join(os.homedir(), '.gemini', 'antigravity');
    this.now = now;
    this.records = new Map();
    this.cursors = new Map();
    this.dirty = false;
    this.source = { online: false, source: '本机 Antigravity 日志', coverage: '最近 64 份会话 · 模型步骤', files: 0, lastUpdated: null };
    this._load();
  }

  _load() {
    if (!this.storagePath) return;
    try {
      const stored = JSON.parse(fs.readFileSync(this.storagePath, 'utf8').replace(/^\uFEFF/, ''));
      for (const row of Array.isArray(stored.records) ? stored.records : []) {
        if (!row || typeof row !== 'object') continue;
        const record = makeRecord({
          step_index: row.stepIndex,
          status: row.status,
          created_at: row.timestamp,
          input_tokens: row.tokens?.input,
          cache_read_tokens: row.tokens?.cache,
          output_tokens: row.tokens?.output
        }, row.sessionId);
        if (record && record.id === row.id) this.records.set(record.id, record);
      }
    } catch {}
  }

  save() {
    if (!this.storagePath || !this.dirty) return;
    const cutoff = this.now().getTime() - 90 * 86400000;
    const records = [...this.records.values()].filter(row => new Date(row.timestamp).getTime() >= cutoff);
    try {
      atomicJson(this.storagePath, { schemaVersion: 2, records });
      this.dirty = false;
    } catch {}
  }

  listFiles() {
    const brain = path.join(this.appDataDir, 'brain');
    const files = [];
    try {
      for (const d of fs.readdirSync(brain, { withFileTypes: true })) {
        if (!d.isDirectory()) continue;
        const p = path.join(brain, d.name, '.system_generated', 'logs', 'transcript_full.jsonl');
        try {
          files.push({ p, mtime: fs.statSync(p).mtimeMs });
        } catch {}
      }
    } catch {}
    return files.sort((a, b) => b.mtime - a.mtime).slice(0, 64).map(f => f.p);
  }

  scan() {
    const files = this.listFiles();
    const active = new Set(files);
    for (const file of this.cursors.keys()) {
      if (!active.has(file)) this.cursors.delete(file);
    }
    let newest = 0;
    let readable = 0;
    for (const file of files) {
      try {
        const stat = fs.statSync(file);
        if (!stat.isFile()) continue;
        let c = this.cursors.get(file);
        if (!c || stat.size < c.offset) {
          c = { offset: 0, pending: Buffer.alloc(0), seen: new Map(), discarding: false };
        }
        const fd = fs.openSync(file, 'r');
        try {
          let budget = 8 * 1024 * 1024;
          while (c.offset < stat.size && budget > 0) {
            const b = Buffer.alloc(Math.min(262144, stat.size - c.offset, budget));
            const n = fs.readSync(fd, b, 0, b.length, c.offset);
            if (!n) break;
            c.offset += n;
            budget -= n;
            c.pending = Buffer.concat([c.pending, b.subarray(0, n)]);
            let end;
            while ((end = c.pending.indexOf(10)) >= 0) {
              const line = c.pending.subarray(0, end);
              c.pending = c.pending.subarray(end + 1);
              if (c.discarding) { c.discarding = false; continue; }
              if (line.length > 4194304) continue;
              let s;
              try { s = JSON.parse(line.toString('utf8')); } catch { continue; }
              if (!Number.isSafeInteger(s.step_index) || s.source !== 'MODEL' || s.type !== 'PLANNER_RESPONSE' || s.status !== 'DONE') continue;
              const signature = [s.status, s.input_tokens, s.cache_read_tokens, s.output_tokens].join('|');
              if (c.seen.get(s.step_index) === signature) continue;
              c.seen.set(s.step_index, signature);
              if (c.seen.size > 10000) c.seen.delete(c.seen.keys().next().value);
              const sessionId = path.basename(path.resolve(file, '../../..'));
              const previous = this.records.get(`${sessionId}:${s.step_index}`);
              const record = makeRecord(s, sessionId, previous);
              if (record && (!previous || JSON.stringify(previous.tokens) !== JSON.stringify(record.tokens))) {
                this.records.set(record.id, record);
                this.dirty = true;
              }
            }
            if (c.pending.length > 4194304) {
              c.pending = Buffer.alloc(0);
              c.discarding = true;
            }
          }
        } finally {
          fs.closeSync(fd);
        }
        this.cursors.set(file, c);
        readable++;
        newest = Math.max(newest, stat.mtimeMs);
      } catch {}
    }
    this.source = {
      online: readable > 0,
      source: '本机 Antigravity 日志',
      coverage: '最近 64 份会话 · 模型步骤',
      files: readable,
      lastUpdated: newest ? new Date(newest).toISOString() : null
    };
    this.save();
    return this.getSnapshot();
  }

  getSnapshot() {
    const date = localDate(this.now());
    const rows = [...this.records.values()].filter(row => row.date === date);
    const sum = key => {
      if (!rows.length || rows.some(row => row.tokens[key] === null)) return null;
      const value = rows.reduce((total, row) => total + row.tokens[key], 0);
      return Number.isSafeInteger(value) ? value : null;
    };
    const partial = rows.some(row => row.tokens.total === null);
    const latest = [...this.records.values()].sort((a, b) => b.timestamp.localeCompare(a.timestamp))[0] || null;
    return {
      date,
      todayTokens: {
        prompt: sum('input'),
        cache: sum('cache'),
        output: sum('output'),
        total: sum('total')
      },
      todaySteps: rows.length,
      latest,
      partial,
      source: this.source,
      updatedAt: Date.now()
    };
  }
}

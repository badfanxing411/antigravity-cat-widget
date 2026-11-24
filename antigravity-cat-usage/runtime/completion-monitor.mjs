import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { discoverHost, CdpClient } from './host-cdp.mjs';

const MAX_READ_BYTES = 4 * 1024 * 1024;
const MAX_LINE_BYTES = 4 * 1024 * 1024;
const MAX_SEEN = 4096;
const RESUME_GRACE_MS = 5000;
const RESUME_STATE_MAX_AGE_MS = 5 * 60 * 1000;

function loadMonitorState(file) {
  try {
    const value = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (value && Number.isFinite(value.at) && Date.now() - value.at < RESUME_STATE_MAX_AGE_MS) {
      return { at: value.at, lastEnded: Number.isFinite(value.lastEnded) ? value.lastEnded : 0 };
    }
  } catch {}
  return null;
}

function saveMonitorState(file, at, lastEnded) {
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify({ at, lastEnded }));
  } catch {}
}

function readWaitingSteps() {
  if (typeof document === 'undefined') return null;
  let store = window.__agyWidgetStore;
  if (typeof store?.getState !== 'function') {
    store = null;
    const seen = new Set();
    for (const el of document.querySelectorAll('body *')) {
      let f = el[Object.keys(el).find(k => k.startsWith('__reactFiber$'))];
      for (; f && !seen.has(f); f = f.return) {
        seen.add(f);
        const st = f.memoizedProps?.value?.store;
        if (typeof st?.getState === 'function' && st.getState()?.trajectorySummaries?.summaries) {
          store = st;
          window.__agyWidgetStore = st;
          break;
        }
      }
      if (store) break;
    }
  }
  if (!store) return null;
  const summaries = store.getState()?.trajectorySummaries?.summaries;
  if (!summaries || typeof summaries !== 'object') return null;
  const keys = [];
  for (const [id, s] of Object.entries(summaries)) {
    const arr = s?.waitingSteps;
    if (!Array.isArray(arr) || !arr.length) continue;
    for (let i = 0; i < arr.length; i++) {
      const w = arr[i];
      const k = typeof w === 'number' || typeof w === 'string'
        ? String(w)
        : (w && typeof w === 'object' ? (w.stepIndex ?? w.step_index ?? w.id ?? i) : i);
      keys.push(id + ':' + k);
    }
  }
  return keys;
}

export class AntigravityCompletionMonitor {
  constructor({ appDataDir = null, intervalMs = 1500, approvalPollMs = 1500, onNotification = () => {}, stateFile = null } = {}) {
    this.appDataDir = appDataDir || path.join(os.homedir(), '.gemini', 'antigravity');
    this.intervalMs = intervalMs;
    this.approvalPollMs = approvalPollMs;
    this.onNotification = onNotification;
    this.stateFile = stateFile;
    this.cursors = new Map();
    this.seenReplies = new Set();
    this.initialized = false;
    this.since = Date.now();
    this.lastEnded = 0;
    this.lastStateSave = 0;
    this.transcriptTimer = null;

    // CDP approval polling state
    this.approvalActive = false;
    this.approvalBusy = false;
    this.approvalTimer = null;
    this.cdpClient = null;
    this.prevWaitingKeys = new Set();
    this.approvalInitialized = false;
  }

  listTranscriptFiles() {
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

  start() {
    if (this.transcriptTimer) return;
    if (this.stateFile) {
      const saved = loadMonitorState(this.stateFile);
      if (saved !== null) {
        this.lastEnded = saved.lastEnded;
        this.since = Math.max(0, Math.max(saved.at - RESUME_GRACE_MS, saved.lastEnded + 1));
      }
    }
    this.scanTranscripts();
    this.persistState(true);
    this.transcriptTimer = setInterval(() => this.scanTranscripts(), this.intervalMs);
    this.transcriptTimer.unref?.();

    this.approvalActive = true;
    this.pollApprovals();
  }

  persistState(force = false) {
    if (!this.stateFile) return;
    const now = Date.now();
    if (!force && now - this.lastStateSave < 5000) return;
    this.lastStateSave = now;
    saveMonitorState(this.stateFile, now, this.lastEnded);
  }

  scanTranscripts() {
    const files = this.listTranscriptFiles();
    const active = new Set(files);
    for (const file of this.cursors.keys()) {
      if (!active.has(file)) this.cursors.delete(file);
    }
    for (const file of files) {
      try {
        const stat = fs.statSync(file);
        if (!stat.isFile()) continue;
        let c = this.cursors.get(file);
        if (!c || stat.size < c.offset) {
          // On initial startup, baseline to EOF unless modified inside resume window
          const baselineSize = !this.initialized && stat.mtimeMs < this.since ? stat.size : 0;
          c = { offset: baselineSize, pending: Buffer.alloc(0), replied: new Set(), discarding: false, baselineSize: !this.initialized ? stat.size : 0 };
        }
        const fd = fs.openSync(file, 'r');
        try {
          let budget = MAX_READ_BYTES;
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
              if (line.length > MAX_LINE_BYTES) continue;
              let s;
              try { s = JSON.parse(line.toString('utf8')); } catch { continue; }
              if (!Number.isSafeInteger(s.step_index) || s.source !== 'MODEL' || s.type !== 'PLANNER_RESPONSE' || s.status !== 'DONE') continue;
              const isFinalReply = !(Array.isArray(s.tool_calls) && s.tool_calls.length > 0) && typeof s.content === 'string' && s.content.trim().length > 0;
              if (!isFinalReply) continue;
              const sessionId = path.basename(path.resolve(file, '../../..'));
              const turnId = String(s.step_index);
              const key = sessionId + '\0' + turnId;
              if (c.replied.has(turnId) || this.seenReplies.has(key)) continue;
              c.replied.add(turnId);
              this.seenReplies.add(key);
              if (this.seenReplies.size > MAX_SEEN) this.seenReplies.delete(this.seenReplies.values().next().value);
              const endedAt = typeof s.created_at === 'string' ? Date.parse(s.created_at) : Date.now();
              const effectiveEndedAt = Number.isFinite(endedAt) ? endedAt : Date.now();
              const historical = !this.initialized && effectiveEndedAt < this.since;
              if (historical) continue;
              if (effectiveEndedAt > this.lastEnded) this.lastEnded = effectiveEndedAt;
              try {
                this.onNotification({ type: 'completion', sessionId, turnId, endedAt: effectiveEndedAt });
              } catch {}
            }
            if (c.pending.length > MAX_LINE_BYTES) {
              c.pending = Buffer.alloc(0);
              c.discarding = true;
            }
          }
        } finally {
          fs.closeSync(fd);
        }
        this.cursors.set(file, c);
      } catch {}
    }
    this.initialized = true;
    this.persistState();
  }

  async pollApprovals() {
    if (!this.approvalActive || this.approvalBusy) return;
    this.approvalBusy = true;
    clearTimeout(this.approvalTimer);
    try {
      if (!this.cdpClient || this.cdpClient.closed) {
        const host = await discoverHost();
        if (!this.approvalActive) return;
        if (!host) throw new Error('offline');
        this.cdpClient = new CdpClient(host.target.webSocketDebuggerUrl);
      }
      const keys = await this.cdpClient.evaluate('(' + readWaitingSteps.toString() + ')()');
      if (!this.approvalActive) return;
      if (Array.isArray(keys)) {
        if (this.approvalInitialized) {
          const fresh = keys.filter(k => !this.prevWaitingKeys.has(k));
          if (fresh.length > 0) {
            try {
              this.onNotification({
                type: 'approval',
                sessionId: 'antigravity-approval',
                turnId: fresh[0],
                endedAt: Date.now(),
                total: keys.length
              });
            } catch {}
          }
        } else {
          this.approvalInitialized = true;
        }
        this.prevWaitingKeys = new Set(keys);
      }
    } catch {
      try { this.cdpClient?.close(); } catch {}
      this.cdpClient = null;
    } finally {
      this.approvalBusy = false;
      if (this.approvalActive) {
        this.approvalTimer = setTimeout(() => this.pollApprovals(), this.cdpClient ? this.approvalPollMs : 4000);
        this.approvalTimer.unref?.();
      }
    }
  }

  stop() {
    if (this.transcriptTimer) clearInterval(this.transcriptTimer);
    this.transcriptTimer = null;
    this.approvalActive = false;
    clearTimeout(this.approvalTimer);
    this.approvalTimer = null;
    try { this.cdpClient?.close(); } catch {}
    this.cdpClient = null;
    this.cursors.clear();
    this.seenReplies.clear();
  }
}

function run() {
  const stateFile = process.argv[2] || null;
  const monitor = new AntigravityCompletionMonitor({
    onNotification: event => process.stdout.write(JSON.stringify(event) + '\n'),
    stateFile
  });
  monitor.start();
  process.stdin.resume();
  process.stdin.on('end', () => { monitor.stop(); process.exit(0); });
  process.on('SIGTERM', () => { monitor.stop(); process.exit(0); });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) run();

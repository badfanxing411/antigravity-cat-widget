import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { normalizeQuotaSample } from '../runtime/usage.mjs';
import { createRefreshQueue, mergeUsageSnapshot } from '../runtime/refresh-queue.mjs';
import { AntigravityLedgerScanner } from '../runtime/ledger.mjs';
import { normalizeWave } from '../runtime/audio-import.mjs';

test('normalizeQuotaSample formats 5h and weekly windows accurately', () => {
  const now = 1795449000000;
  const sample = {
    cacheAvailable: true,
    fiveHour: 82.4,
    weekly: 91.2,
    fiveHourResetAt: now + 3600_000,
    weeklyResetAt: now + 86400_000
  };
  const out = normalizeQuotaSample(sample, { hostKey: 'host-1', now });
  assert.equal(out.ok, true);
  assert.equal(out.queryOk, true);
  assert.equal(out.windows.length, 2);
  assert.equal(out.windows[0].label, '5 小时');
  assert.equal(out.windows[0].remaining, 82.4);
  assert.equal(out.windows[0].used, 17.6);
  assert.equal(out.windows[0].resetsAt, Math.floor((now + 3600_000) / 1000));
  assert.equal(out.windows[1].label, '每周');
  assert.equal(out.windows[1].remaining, 91.2);
});

test('mergeUsageSnapshot preserves previous valid quota when transient refresh fails', () => {
  const now = 1795449000000;
  const prev = normalizeQuotaSample({ cacheAvailable: true, fiveHour: 75, weekly: 80 }, { hostKey: 'h1', now });
  const fail = normalizeQuotaSample({ cacheAvailable: false }, { hostKey: 'h1', now: now + 5000 });
  const merged = mergeUsageSnapshot(prev, fail, now + 5000);
  assert.equal(merged.ok, true);
  assert.equal(merged.queryOk, false);
  assert.equal(merged.windows.length, 2);
  assert.equal(merged.windows[0].remaining, 75);
});

test('createRefreshQueue coalesces concurrent refresh requests', async () => {
  let runs = 0;
  const queue = createRefreshQueue(async () => {
    runs++;
    await new Promise(r => setTimeout(r, 15));
  });
  const p1 = queue.request();
  const p2 = queue.request();
  const p3 = queue.request();
  await Promise.all([p1, p2, p3]);
  assert.equal(runs, 2);
});

test('AntigravityLedgerScanner aggregates today tokens and latest step from transcript jsonl', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'agy-cat-ledger-'));
  try {
    const logDir = path.join(tmp, 'brain', 'sess-1', '.system_generated', 'logs');
    fs.mkdirSync(logDir, { recursive: true });
    const t1 = new Date(Date.now() - 2000).toISOString();
    const t2 = new Date().toISOString();
    fs.writeFileSync(path.join(logDir, 'transcript_full.jsonl'), [
      JSON.stringify({ step_index: 1, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', created_at: t1, input_tokens: 100, cache_read_tokens: 500, output_tokens: 40 }),
      JSON.stringify({ step_index: 2, source: 'MODEL', type: 'PLANNER_RESPONSE', status: 'DONE', created_at: t2, input_tokens: 200, cache_read_tokens: 300, output_tokens: 60 })
    ].join('\n') + '\n', 'utf8');
    const scanner = new AntigravityLedgerScanner({ appDataDir: tmp, storagePath: path.join(tmp, 'usage-v2.json') });
    const snap = scanner.scan();
    assert.equal(snap.todaySteps, 2);
    assert.equal(snap.todayTokens.prompt, 300);
    assert.equal(snap.todayTokens.cache, 800);
    assert.equal(snap.todayTokens.output, 100);
    assert.equal(snap.todayTokens.total, 1200);
    assert.equal(snap.latest.stepIndex, 2);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test('normalizeWave accepts bundled sound presets', () => {
  const wav = fs.readFileSync(new URL('../assets/sounds/bubble-pop-press.wav', import.meta.url));
  const out = normalizeWave(wav);
  assert.equal(out.channels, 1);
  assert.equal(out.sampleRate, 44100);
  assert.ok(out.duration > 0 && out.duration <= 5);
});

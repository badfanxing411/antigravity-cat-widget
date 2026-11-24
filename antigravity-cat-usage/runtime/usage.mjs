import fs from 'node:fs';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { discoverHost, hasDevToolsPortFile, CdpClient } from './host-cdp.mjs';

// Read only quota fields from the native IDE cache or Desktop Models view cache.
function readHostQuota() {
  const result = { fiveHour: null, weekly: null, fetchedAt: null };
  const groups = typeof nY !== 'undefined' && Array.isArray(nY)
    ? nY
    : typeof pY !== 'undefined' && Array.isArray(pY) ? pY : [];
  let group = groups.find(g => g && g.displayName === 'Gemini Models');
  if (!group && typeof document !== 'undefined') {
    const seen = new Set();
    for (const el of document.querySelectorAll('[role=dialog] *')) {
      let fiber = el[Object.keys(el).find(k => k.startsWith('__reactFiber$'))];
      for (let i = 0; fiber && i < 40; fiber = fiber.return, i++) {
        if (seen.has(fiber)) break;
        seen.add(fiber);
        for (let state = fiber.memoizedState, j = 0; state && j < 80; state = state.next, j++) {
          if (Array.isArray(state.memoizedState)) {
            group = state.memoizedState.find(g => g && g.displayName === 'Gemini Models') || group;
          }
        }
      }
      if (group) break;
    }
  }
  if (!group) return result;
  result.cacheAvailable = true;
  for (const b of group.buckets || []) {
    const key = b.bucketId === 'gemini-5h' ? 'fiveHour' : b.bucketId === 'gemini-weekly' ? 'weekly' : null;
    const value = b.remaining?.case === 'remainingFraction' ? b.remaining.value : null;
    if (key && !b.disabled && typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1) {
      result[key] = value * 100;
    }
    if (key && !b.disabled) {
      const r = b.resetTime;
      let at = null;
      if (r) {
        if (typeof r === 'string') at = Date.parse(r);
        else if (r instanceof Date) at = r.getTime();
        else if (r.seconds !== undefined && r.seconds !== null) {
          at = Number(r.seconds) * 1000 + Math.floor(Number(r.nanos || 0) / 1e6);
        }
      }
      if (typeof at === 'number' && Number.isFinite(at) && at > 0) result[key + 'ResetAt'] = at;
    }
  }
  const timestamp = typeof nY !== 'undefined' && Array.isArray(nY) && typeof mFb === 'number'
    ? mFb
    : typeof jFb === 'number' ? jFb : null;
  if (typeof timestamp === 'number' && Number.isFinite(timestamp) && timestamp > 0 && timestamp <= Date.now() + 60000) {
    result.fetchedAt = timestamp;
  }
  return result;
}

// Uses only the logged-in host's quota service; no credentials or conversation data leave the host.
async function queryHostQuota(readCache) {
  const seen = new Set();
  if (typeof document !== 'undefined') {
    for (const el of document.querySelectorAll('body *')) {
      let fiber = el[Object.keys(el).find(k => k.startsWith('__reactFiber$'))];
      for (; fiber && !seen.has(fiber); fiber = fiber.return) {
        seen.add(fiber);
        const service = fiber.memoizedProps?.value?.core?.cloudCodeService;
        if (typeof service?.retrieveUserQuotaSummary !== 'function') continue;
        const response = await service.retrieveUserQuotaSummary(undefined, false);
        const group = response?.response?.groups?.find(g => g?.displayName === 'Gemini Models');
        if (!group) throw Error('Gemini quota group unavailable');
        const result = { cacheAvailable: true, fiveHour: null, weekly: null, fetchedAt: null };
        for (const bucket of group.buckets || []) {
          const key = bucket.bucketId === 'gemini-5h' ? 'fiveHour' : bucket.bucketId === 'gemini-weekly' ? 'weekly' : null;
          const value = bucket.remaining?.case === 'remainingFraction' ? bucket.remaining.value : null;
          if (key && !bucket.disabled && typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1) {
            result[key] = value * 100;
          }
          if (key && !bucket.disabled) {
            const r = bucket.resetTime;
            let at = null;
            if (r) {
              if (typeof r === 'string') at = Date.parse(r);
              else if (r instanceof Date) at = r.getTime();
              else if (r.seconds !== undefined && r.seconds !== null) {
                at = Number(r.seconds) * 1000 + Math.floor(Number(r.nanos || 0) / 1e6);
              }
            }
            if (typeof at === 'number' && Number.isFinite(at) && at > 0) result[key + 'ResetAt'] = at;
          }
        }
        return result;
      }
    }
  }
  return readCache();
}

function toResetSeconds(ms) {
  if (typeof ms !== 'number' || !Number.isFinite(ms) || ms <= 0) return null;
  const sec = Math.floor(ms / 1000);
  return sec > 0 && sec <= 253402271999 ? sec : null;
}

export function normalizeQuotaSample(sample, { hostKey = null, now = Date.now() } = {}) {
  if (!sample || !sample.cacheAvailable) {
    return {
      ok: false,
      queryOk: false,
      source: 'antigravity-cdp',
      planLabel: 'Gemini Models',
      observedAt: now,
      windows: [],
      accountKey: hostKey,
      clearPrevious: false,
      errorCode: 'INITIALIZING',
      error: 'Antigravity 正在初始化或尚未加载额度'
    };
  }
  const windows = [];
  const addWindow = (label, minutes, remaining, resetMs) => {
    if (typeof remaining !== 'number' || !Number.isFinite(remaining) || remaining < 0 || remaining > 100) return;
    const clamped = Math.max(0, Math.min(100, remaining));
    windows.push({
      label,
      minutes,
      remaining: Math.round(clamped * 10) / 10,
      used: Math.round((100 - clamped) * 10) / 10,
      resetsAt: toResetSeconds(resetMs)
    });
  };
  addWindow('5 小时', 300, sample.fiveHour, sample.fiveHourResetAt);
  addWindow('每周', 10080, sample.weekly, sample.weeklyResetAt);

  if (windows.length === 0) {
    return {
      ok: false,
      queryOk: true,
      source: 'antigravity-cdp',
      planLabel: 'Gemini Models',
      observedAt: now,
      windows: [],
      accountKey: hostKey,
      clearPrevious: true,
      errorCode: 'NO_WINDOWS',
      error: '当前 Antigravity 未返回可显示的 Gemini 额度窗口'
    };
  }
  return {
    ok: true,
    queryOk: true,
    source: 'antigravity-cdp',
    planLabel: 'Gemini Models',
    observedAt: now,
    fetchedAt: typeof sample.fetchedAt === 'number' ? sample.fetchedAt : null,
    windows,
    accountKey: hostKey,
    clearPrevious: false
  };
}

export async function readUsage({ discover = discoverHost, Client = CdpClient, now = Date.now } = {}) {
  let client = null;
  try {
    const host = await discover();
    if (!host) {
      const hasPort = hasDevToolsPortFile();
      return {
        ok: false,
        queryOk: false,
        source: 'antigravity-cdp',
        planLabel: 'Gemini Models',
        observedAt: now(),
        windows: [],
        accountKey: null,
        clearPrevious: false,
        errorCode: hasPort ? 'WAITING_HOST' : 'CDP_NOT_ENABLED',
        error: hasPort
          ? '等待连接 Antigravity 主窗口'
          : 'Antigravity 未开启本机调试端口，请用「启动Antigravity(含星猫额度).vbs」启动以读取实时额度'
      };
    }
    const hostKey = createHash('sha256').update(host.target.webSocketDebuggerUrl).digest('hex').slice(0, 32);
    client = new Client(host.target.webSocketDebuggerUrl);
    const sample = await client.evaluate('(' + queryHostQuota.toString() + ')(' + readHostQuota.toString() + ')');
    return normalizeQuotaSample(sample, { hostKey, now: now() });
  } catch (error) {
    return {
      ok: false,
      queryOk: false,
      source: 'antigravity-cdp',
      planLabel: 'Gemini Models',
      observedAt: now(),
      windows: [],
      accountKey: null,
      clearPrevious: false,
      errorCode: 'QUERY_FAILED',
      error: error?.message ? `额度读取失败：${error.message}` : '暂时无法读取 Antigravity 额度'
    };
  } finally {
    try { client?.close(); } catch {}
  }
}

export function atomicJson(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = file + '.' + process.pid + '.' + randomUUID() + '.tmp';
  try {
    fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + '\n', 'utf8');
    fs.renameSync(tmp, file);
  } finally {
    try { fs.unlinkSync(tmp); } catch {}
  }
}

export function freshness(window, observedAt, now = Date.now()) {
  if (!window || !Number.isFinite(observedAt)) return 'unavailable';
  if (Number.isFinite(window.resetsAt) && window.resetsAt > 0 && window.resetsAt * 1000 <= now) return 'expired';
  return now - observedAt > 180000 ? 'stale' : 'fresh';
}

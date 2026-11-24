import fs from 'node:fs';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import net from 'node:net';
import { atomicJson } from './usage.mjs';

export function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '')); } catch { return null; }
}

export function processAlive(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; } catch (error) { return error.code === 'EPERM'; }
}

export function healthyWorker(dataDir, now = Date.now()) {
  const status = readJson(path.join(dataDir, 'worker-status.json'));
  const owner = readJson(path.join(dataDir, 'worker.lock'));
  return status && owner && status.token === owner.token && status.pid === owner.pid
    && now - status.at >= 0 && now - status.at < 5000
    && processAlive(status.pid) && (!status.parentPid || processAlive(status.parentPid))
    ? status
    : null;
}

export function workerEndpoint(dataDir) {
  const key = createHash('sha256').update(path.resolve(dataDir).toLowerCase()).digest('hex').slice(0, 32);
  return process.platform === 'win32'
    ? '\\\\.\\pipe\\antigravity-cat-usage-' + key
    : path.join(dataDir, 'worker.sock');
}

export async function acquireWorkerLock(dataDir, parentPid = 0, { pid = process.pid, onConnection = socket => socket.destroy() } = {}) {
  fs.mkdirSync(dataDir, { recursive: true });
  const file = path.join(dataDir, 'worker.lock');
  const owner = { pid, parentPid, token: randomUUID(), startedAt: Date.now() };
  const endpoint = workerEndpoint(dataDir);
  const server = net.createServer(onConnection);
  const claimed = await new Promise((resolve, reject) => {
    server.once('error', error => (error.code === 'EADDRINUSE' ? resolve(false) : reject(error)));
    server.listen(endpoint, () => resolve(true));
  });
  if (!claimed) return null;
  try { atomicJson(file, owner); } catch (error) { server.close(); throw error; }
  return {
    owner,
    release() {
      try { if (readJson(file)?.token === owner.token) fs.unlinkSync(file); } catch {}
      return new Promise(resolve => server.close(resolve));
    }
  };
}

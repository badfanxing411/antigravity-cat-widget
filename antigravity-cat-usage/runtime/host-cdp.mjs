import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const WebSocket = require('./vendor/ws/index.js');

function getJson(port, resource) {
  return new Promise((resolve, reject) => {
    const req = http.get({ hostname: '127.0.0.1', port, path: resource, timeout: 1800 }, res => {
      let data = '';
      res.on('data', b => {
        data += b;
        if (data.length > 1048576) req.destroy();
      });
      res.on('end', () => {
        try {
          resolve(JSON.parse(data));
        } catch {
          reject(new Error('宿主端点返回无效数据'));
        }
      });
    });
    req.on('timeout', () => req.destroy(new Error('宿主响应超时')));
    req.on('error', reject);
  });
}

export function hasDevToolsPortFile() {
  const candidates = [
    path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), 'Antigravity', 'DevToolsActivePort'),
    path.join(os.homedir(), 'Library', 'Application Support', 'Antigravity', 'DevToolsActivePort'),
    path.join(os.homedir(), '.config', 'Antigravity', 'DevToolsActivePort')
  ];
  return candidates.some(file => {
    try { return fs.existsSync(file); } catch { return false; }
  });
}

export async function discoverHost() {
  const candidates = [
    path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), 'Antigravity', 'DevToolsActivePort'),
    path.join(os.homedir(), 'Library', 'Application Support', 'Antigravity', 'DevToolsActivePort'),
    path.join(os.homedir(), '.config', 'Antigravity', 'DevToolsActivePort')
  ];
  for (const file of candidates) {
    try {
      const port = Number(fs.readFileSync(file, 'utf8').split(/\r?\n/)[0]);
      if (!Number.isInteger(port) || port < 1 || port > 65535) continue;
      const targets = await getJson(port, '/json/list');
      const target = targets.find(t => t.type === 'page' && /^https?:\/\/127\.0\.0\.1:\d+\//.test(t.url));
      if (target && /^ws:\/\/(127\.0\.0\.1|localhost):\d+\//.test(target.webSocketDebuggerUrl)) {
        return { port, target };
      }
    } catch {}
  }
  return null;
}

export class CdpClient {
  constructor(url, options = {}) {
    if (!/^ws:\/\/(127\.0\.0\.1|localhost):\d+\//.test(url)) {
      throw new Error('仅允许连接本机 Antigravity 宿主');
    }
    const handshakeTimeout = Number.isFinite(options.handshakeTimeout)
      ? Math.max(20, Math.min(10000, options.handshakeTimeout))
      : 4000;
    this.socket = new WebSocket(url, { maxPayload: 5 * 1024 * 1024, handshakeTimeout });
    this.pending = new Map();
    this.id = 0;
    this.closed = false;
    this.ready = new Promise((resolve, reject) => {
      this.socket.once('open', resolve);
      this.socket.once('error', reject);
    });
    this.socket.on('message', raw => {
      try {
        const m = JSON.parse(raw);
        const p = this.pending.get(m.id);
        if (p) {
          this.pending.delete(m.id);
          clearTimeout(p.timer);
          if (m.error) p.reject(new Error(m.error.message));
          else p.resolve(m.result);
        }
      } catch {}
    });
    this.socket.on('error', () => {});
    this.socket.on('close', () => {
      this.closed = true;
      for (const p of this.pending.values()) {
        clearTimeout(p.timer);
        p.reject(new Error('宿主连接已断开'));
      }
      this.pending.clear();
    });
  }

  async send(method, params = {}) {
    await this.ready;
    if (this.closed) throw new Error('宿主连接已断开');
    return new Promise((resolve, reject) => {
      const id = ++this.id;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error('宿主操作超时'));
      }, 7000);
      this.pending.set(id, { resolve, reject, timer });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  async evaluate(expression) {
    const out = await this.send('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: true
    });
    if (out.exceptionDetails) {
      throw new Error(out.exceptionDetails.exception?.description || out.exceptionDetails.text || '宿主执行失败');
    }
    return out.result?.value;
  }

  close() {
    this.closed = true;
    try {
      this.socket.close();
    } catch {}
  }
}

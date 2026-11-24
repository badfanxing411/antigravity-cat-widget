import { readUsage } from './usage.mjs';
import { AntigravityLedgerScanner } from './ledger.mjs';

const json = process.argv.includes('--json');
const quota = await readUsage();
const scanner = new AntigravityLedgerScanner();
const ledger = scanner.scan();

if (json) {
  console.log(JSON.stringify({ quota, ledger }, null, 2));
} else {
  console.log('=== Antigravity 星猫 · 额度检测 ===');
  if (quota.ok) {
    console.log('连接状态：已读取实时额度 (' + (quota.planLabel || 'Gemini Models') + ')');
    for (const w of quota.windows || []) {
      const reset = w.resetsAt ? new Date(w.resetsAt * 1000).toLocaleString() : '未提供重置时间';
      console.log(`  - ${w.label}：剩余 ${w.remaining}%（已用 ${w.used}%），重置：${reset}`);
    }
  } else {
    console.log('连接状态：未读取到实时额度');
    console.log('原因：' + (quota.error || '未知错误'));
    console.log('提示：请确认 Antigravity 桌面端已打开且处于登录状态。');
  }
  console.log('--- 本机日志统计 ---');
  console.log(`日志文件数：${ledger.source?.files ?? 0}，今日模型步骤：${ledger.todaySteps}`);
  if (ledger.todayTokens?.total != null) {
    console.log(`今日总 Token：${ledger.todayTokens.total.toLocaleString()} (输入 ${ledger.todayTokens.prompt?.toLocaleString() ?? '—'} · 缓存 ${ledger.todayTokens.cache?.toLocaleString() ?? '—'} · 输出 ${ledger.todayTokens.output?.toLocaleString() ?? '—'})`);
  }
}
process.exitCode = quota.ok ? 0 : 1;

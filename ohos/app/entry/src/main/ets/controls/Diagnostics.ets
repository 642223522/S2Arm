// Remote-friendly diagnostics: a session marker that survives a crash, the runtime logs the engine
// already writes (files/runtime-*.log, states/<TitleID>/host-*.log), system crash logs delivered by
// hiAppEvent, and one exported text file the player can send back. Nothing here reads save data.
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { hiAppEvent } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

export interface SessionInfo { key: string; title: string; titleId: string; mode: string; started: number; }

const ACTIVE = '/session-active.json';
const LAST = '/session-last.json';

function writeText(path: string, text: string): void {
  const file = fs.openSync(path + '.tmp', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try { fs.writeSync(file.fd, text); } finally { fs.closeSync(file); }
  fs.renameSync(path + '.tmp', path);
}

export function markSessionStart(files: string, info: SessionInfo): void {
  try { writeText(files + ACTIVE, JSON.stringify(info)); } catch (error) { console.error('S2Arm session marker not written'); }
}
// A normal return to the library (or a reported failure) clears the marker; a crash leaves it behind.
export function markSessionEnd(files: string): void {
  try { if (fs.accessSync(files + ACTIVE)) fs.unlinkSync(files + ACTIVE); } catch (error) { /* keep going */ }
}
export function takeUnfinishedSession(files: string): SessionInfo | undefined {
  try {
    if (!fs.accessSync(files + ACTIVE)) return undefined;
    const info = JSON.parse(fs.readTextSync(files + ACTIVE)) as SessionInfo;
    fs.renameSync(files + ACTIVE, files + LAST);
    return info;
  } catch (error) { return undefined; }
}

interface LogFile { path: string; name: string; mtime: number; size: number; }

function listLogs(dir: string, pattern: RegExp, out: LogFile[]): void {
  try {
    if (!fs.accessSync(dir)) return;
    for (const name of fs.listFileSync(dir, { recursion: false, listNum: 4096 })) {
      if (!pattern.test(name)) continue;
      const path = dir + '/' + name;
      const st = fs.statSync(path);
      if (st.isFile()) out.push({ path: path, name: name, mtime: st.mtime, size: st.size });
    }
  } catch (error) { /* a directory we cannot read contributes nothing */ }
}

function recentLogs(files: string): LogFile[] {
  const logs: LogFile[] = [];
  listLogs(files, /^runtime-\d+-\d+\.log$/, logs);
  listLogs(files + '/crash', /^crash-.*\.log$/, logs);
  try {
    const states = files + '/states';
    if (fs.accessSync(states)) {
      for (const id of fs.listFileSync(states, { recursion: false, listNum: 256 })) {
        if (/^[0-9A-F]{16}$/.test(id)) listLogs(states + '/' + id, /^host-.*\.log$/, logs);
      }
    }
  } catch (error) { /* ignore */ }
  logs.sort((a: LogFile, b: LogFile) => b.mtime - a.mtime);
  return logs;
}

function tail(path: string, size: number, limit: number): string {
  const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
  try {
    const length = Math.min(size, limit);
    const buffer = new ArrayBuffer(length);
    const read = fs.readSync(file.fd, buffer, { offset: Math.max(0, size - length), length: length });
    const text = util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(new Uint8Array(buffer, 0, read));
    return (size > length ? '…（前 ' + (size - length).toString() + ' 字节省略）\n' : '') + text;
  } finally { fs.closeSync(file); }
}

// The newest failure lines are what a remote player can read off the screen; keep them short.
export function lastFailureLines(files: string, count: number): string[] {
  const logs = recentLogs(files);
  for (const log of logs) {
    if (log.name.startsWith('runtime-')) continue;
    const lines = tail(log.path, log.size, 64 * 1024).split('\n');
    const hits = lines.filter((line: string) =>
      /fail|FATAL|refused|abort|SIG[A-Z]+|exception|error=|missing|unsupported/i.test(line));
    if (hits.length > 0) return hits.slice(Math.max(0, hits.length - count));
  }
  return [];
}

export function buildReport(files: string, appVersion: string): string {
  const parts: string[] = [];
  parts.push('S2Arm 诊断报告  ' + new Date().toISOString());
  parts.push('应用 ' + appVersion + ' · 设备 ' + deviceInfo.marketName + ' (' + deviceInfo.productModel + ') · 系统 ' +
    deviceInfo.displayVersion + ' · API ' + deviceInfo.sdkApiVersion.toString());
  try {
    if (fs.accessSync(files + LAST)) parts.push('上次未正常结束的游戏：' + fs.readTextSync(files + LAST));
  } catch (error) { /* ignore */ }
  const logs = recentLogs(files);
  let budget = 3 * 1024 * 1024;
  let taken = 0;
  for (const log of logs) {
    if (taken >= 6 || budget <= 0) break;
    const limit = Math.min(budget, log.name.startsWith('host-') ? 1024 * 1024 : 256 * 1024);
    parts.push('\n===== ' + log.path.substring(files.length) + '  ' + log.size.toString() + ' B  ' +
      new Date(log.mtime * 1000).toISOString() + ' =====');
    try { parts.push(tail(log.path, log.size, limit)); } catch (error) { parts.push('（无法读取）'); }
    budget -= limit; taken++;
  }
  if (logs.length === 0) parts.push('\n没有找到运行日志。');
  return parts.join('\n');
}

// Saves through the system file picker, so the player chooses where it goes (Downloads, cloud drive…).
export async function exportReport(context: common.UIAbilityContext, files: string, appVersion: string): Promise<string> {
  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace('T', '-').substring(0, 15);
  const options = new picker.DocumentSaveOptions();
  options.newFileNames = ['S2Arm-诊断-' + stamp + '.txt'];
  const uris = await new picker.DocumentViewPicker(context).save(options);
  if (uris.length === 0) return '';
  const file = fs.openSync(uris[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try { fs.writeSync(file.fd, buildReport(files, appVersion)); } finally { fs.closeSync(file); }
  return options.newFileNames[0];
}

// System crash logs (signals the engine could not report itself) arrive on the next launch.
export function installCrashWatcher(files: string): void {
  try {
    hiAppEvent.addWatcher({
      name: 's2arm_crash',
      appEventFilters: [{ domain: hiAppEvent.domain.OS, names: [hiAppEvent.event.APP_CRASH] }],
      onReceive: (domain: string, groups: Array<hiAppEvent.AppEventGroup>) => {
        const dir = files + '/crash';
        try { if (!fs.accessSync(dir)) fs.mkdirSync(dir); } catch (error) { return; }
        for (const group of groups) {
          for (const info of group.appEventInfos) {
            const logs = info.params['external_log'] as string[] | undefined;
            const stamp = Date.now().toString();
            if (!Array.isArray(logs)) {
              try { writeText(dir + '/crash-' + stamp + '.log', JSON.stringify(info.params)); } catch (error) { /* ignore */ }
              continue;
            }
            logs.forEach((source: string, index: number) => {
              try { fs.copyFileSync(source, dir + '/crash-' + stamp + '-' + index.toString() + '.log'); }
              catch (error) { console.error('S2Arm crash log copy failed'); }
            });
          }
        }
      }
    });
  } catch (error) { console.error('S2Arm crash watcher unavailable'); }
}

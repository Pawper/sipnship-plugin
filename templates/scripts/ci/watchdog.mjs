#!/usr/bin/env node
// The watchdog on a build machine: ends a runaway process of the agents'
// tools, records what it was first, and says so. One decided exception to
// "machine health is a recommendation": for runaway processes only.
//
// It ends a process of the agents' tools (git, a shell and its small tools,
// Node started by them) that holds more than 20 GB, or has run over three
// hours with no live session, runner job or drive tick above it. It never
// ends the coordinating session, a runner's service or its listener, the
// drive, the runner's own job, or anything started by hand outside the
// agents' tools. Past 85% of the commit limit it only names the five largest
// processes (a recommendation, as before).
//
// The runner watch (scripts/ci/runner-watch.sh) calls it every fifteen
// minutes and makes sure a one-minute task keeps it going, so there is no
// setup step. Usage:
//   node scripts/ci/watchdog.mjs            one tick: read, decide, record, end, say
//   node scripts/ci/watchdog.mjs --print    read and decide; end and write nothing
//   node scripts/ci/watchdog.mjs --ensure-task   register the one-minute task if it is missing
// Settings, all optional, in ~/.sipnship/watchdog.json: limitGb (20),
// hours (3), warnPercent (85).

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const DEFAULTS = { limitGb: 20, hours: 3, warnPercent: 85 };
const GB = 1024 ** 3;
const HOUR = 3600000;

// Programs of the agents' tools: git and the shell and its small tools.
const TOOLS = new Set(['git', 'sh', 'bash', 'cat', 'grep', 'rg', 'sed', 'awk', 'find', 'sort', 'head', 'tail', 'xargs', 'curl', 'gh', 'tr', 'wc', 'diff', 'cmd', 'powershell', 'pwsh']);
// A live session or job above a process: the coordinating session, the
// runner's job. A process under one is not an orphan.
const LIVE_ABOVE = new Set(['claude', 'runner.worker']);
// Never ended, whatever they hold.
const NEVER = new Set(['claude', 'runner.listener', 'runner.worker', 'runnerservice', 'runner.service', 'system', 'registry', 'memory compression', 'explorer', 'windowsterminal', 'openconsole', 'mintty', 'wininit', 'csrss', 'smss', 'services', 'lsass', 'svchost']);
// Started by a person at their own keyboard.
const BY_HAND = new Set(['explorer', 'windowsterminal', 'openconsole', 'wt', 'mintty', 'code', 'cursor']);
// The drive's tick and the queue are named by their command line.
const NEVER_CMD = /project-drive|sipnship rounds|\bdrive[\\/]plan\.sh|runsvc|runner\.listener|watchdog\.mjs/i;

// What an agent's shell or a runner's job carries in its command line: the shell snapshot a session starts every shell from, the runner's folders.
const AGENT_CMD = /shell-snapshots|[\\/]\.claude[\\/]|actions-runner|_work[\\/]/i;

const base = (name) => String(name || '').toLowerCase().replace(/\.exe$/, '');
const isTool = (p) => { const n = base(p.name); return TOOLS.has(n) || n.startsWith('git-'); };

// Ancestors still running, nearest first. A parent counts only if it was
// started before its child (a reused number is not a parent).
export function ancestors(p, byPid) {
  const out = [];
  let cur = p;
  const seen = new Set([p.pid]);
  while (cur && cur.ppid && !seen.has(cur.ppid) && out.length < 12) {
    const par = byPid.get(cur.ppid);
    if (!par || par.startMs > cur.startMs) break;
    seen.add(par.pid);
    out.push(par);
    cur = par;
  }
  return out;
}

// The decision, pure: from a process list, say who is to be ended and why,
// and what to warn about. `processes`: { pid, ppid, name, cmd, startMs, bytes }.
// `memory`: { usedBytes, limitBytes }. Returns { end: [{ process, why, chain }], warn }.
export function decide(processes, now, memory, settings = {}, selfPid = 0) {
  const s = { ...DEFAULTS, ...settings };
  const byPid = new Map(processes.map((p) => [p.pid, p]));
  const end = [];
  for (const p of processes) {
    if (p.pid === selfPid) continue;
    const name = base(p.name);
    if (NEVER.has(name) || NEVER_CMD.test(p.cmd || '')) continue;
    const up = ancestors(p, byPid);
    const upNames = up.map((a) => base(a.name));
    // Under a person's own terminal it is theirs, not the agents'. (A session started from a person's desktop sits under their explorer too; the nearest of the two decides.)
    const nearest = upNames.find((n) => BY_HAND.has(n) || LIVE_ABOVE.has(n));
    if (nearest && BY_HAND.has(nearest)) continue;
    // It is the agents' only when a live session or job is above it, or everything above it that still runs is one of their tools and one of them carries the agents' own mark (a nest left behind by a session that ended). A shell under a browser or a script host, or a tunnel script a person left running, is not.
    const live = upNames.some((n) => LIVE_ABOVE.has(n));
    const agentChain = live || (up.every((a) => isTool(a) || base(a.name) === 'node') && [p, ...up].some((a) => AGENT_CMD.test(a.cmd || '')));
    const fromTools = (isTool(p) && agentChain) || (name === 'node' && agentChain && up.some((a) => isTool(a) || LIVE_ABOVE.has(base(a.name))));
    if (!fromTools) continue;
    const ranMs = now - p.startMs;
    if (p.bytes > s.limitGb * GB) end.push({ process: p, why: 'size', chain: up, ranMs });
    else if (!live && ranMs > s.hours * HOUR) end.push({ process: p, why: 'orphan', chain: up, ranMs });
  }
  let warn = null;
  if (memory && memory.limitBytes > 0 && memory.usedBytes / memory.limitBytes * 100 > s.warnPercent) {
    const top = [...processes].sort((a, b) => b.bytes - a.bytes).slice(0, 5);
    warn = { percent: Math.round(memory.usedBytes / memory.limitBytes * 100), top };
  }
  return { end, warn };
}

const size = (b) => (b >= GB ? `${(b / GB).toFixed(1)} GB` : `${Math.max(1, Math.round(b / 1048576))} MB`);
const span = (ms) => { const m = Math.round(ms / 60000); return m >= 120 ? `${Math.round(m / 6) / 10} hours` : m === 1 ? '1 minute' : `${m} minutes`; };

// What the record holds, before the process is ended.
export function recordOf(item, now, cwd) {
  const p = item.process;
  return {
    at: new Date(now).toISOString(),
    program: p.name,
    pid: p.pid,
    command: p.cmd || '',
    folder: cwd || null,
    parents: item.chain.map((a) => ({ program: a.name, pid: a.pid, command: (a.cmd || '').slice(0, 300) })),
    parentEnded: p.ppid && !item.chain.length ? p.ppid : null,
    bytes: p.bytes,
    started: new Date(p.startMs).toISOString(),
    ranMinutes: Math.round(item.ranMs / 60000),
    why: item.why,
  };
}

// The one sentence for the Brief and the machine line: what it was, how
// big, how long, and that it was ended.
export function sentence(rec, outcome) {
  const what = rec.program.replace(/\.exe$/i, '');
  const why = rec.why === 'size' ? 'it had filled the machine\'s memory' : 'nothing was running it any more';
  if (outcome === 'ended') return `The watchdog ended a ${what} process holding ${size(rec.bytes)} that had run for ${span(rec.ranMinutes * 60000)}, because ${why}. Its record is in watchdog.log.`;
  return `The watchdog tried to end a ${what} process holding ${size(rec.bytes)} that had run for ${span(rec.ranMinutes * 60000)}, but Windows would not let it. It is still running; its record is in watchdog.log.`;
}

export function warnSentence(w) {
  const list = w.top.map((p) => `${p.name.replace(/\.exe$/i, '')} ${size(p.bytes)}`).join(', ');
  return `Memory is ${w.percent}% full. The five largest: ${list}. Restarting the largest would help.`;
}

export const homeDir = (env = process.env) => path.join(env.SIPNSHIP_HOME || path.join(os.homedir(), '.sipnship'), 'runner-watch');

export function readSettings(env = process.env) {
  try { return JSON.parse(fs.readFileSync(path.join(env.SIPNSHIP_HOME || path.join(os.homedir(), '.sipnship'), 'watchdog.json'), 'utf8')); } catch { return {}; }
}

const PS = String.raw`
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class Cwd {
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int c, byte[] i, int l, out int r);
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int a, bool i, int p);
  [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr h, IntPtr a, byte[] b, int n, out int r);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  static IntPtr P(byte[] b, int o) { return new IntPtr(BitConverter.ToInt64(b, o)); }
  public static string Of(int pid) {
    IntPtr h = OpenProcess(0x0410, false, pid); if (h == IntPtr.Zero) return null;
    try {
      byte[] pbi = new byte[48]; int r;
      if (NtQueryInformationProcess(h, 0, pbi, 48, out r) != 0) return null;
      byte[] peb = new byte[0x30]; if (!ReadProcessMemory(h, P(pbi, 8), peb, peb.Length, out r)) return null;
      byte[] pp = new byte[0x50]; if (!ReadProcessMemory(h, P(peb, 0x20), pp, pp.Length, out r)) return null;
      int len = BitConverter.ToUInt16(pp, 0x38); if (len <= 0 || len > 4096) return null;
      byte[] s = new byte[len]; if (!ReadProcessMemory(h, P(pp, 0x40), s, len, out r)) return null;
      return Encoding.Unicode.GetString(s);
    } catch { return null; } finally { CloseHandle(h); }
  }
}
'@
`;

const ps = (script, timeout = 60000) => {
  const r = spawnSync('powershell', ['-NoProfile', '-Command', script], { encoding: 'utf8', timeout, windowsHide: true, maxBuffer: 64 * 1024 * 1024 });
  return r.status === 0 ? r.stdout : '';
};

// The machine's processes and commit: Windows by PowerShell, elsewhere by ps.
export function readMachine(platform = process.platform) {
  if (platform === 'win32') {
    const out = ps(`$os = Get-CimInstance Win32_OperatingSystem
$ps = Get-CimInstance Win32_Process | ForEach-Object { [pscustomobject]@{ pid = $_.ProcessId; ppid = $_.ParentProcessId; name = $_.Name; cmd = $_.CommandLine; startMs = if ($_.CreationDate) { [DateTimeOffset]::new($_.CreationDate).ToUnixTimeMilliseconds() } else { 0 }; bytes = [int64]$_.PrivatePageCount } }
@{ usedBytes = [int64](($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) * 1024); limitBytes = [int64]($os.TotalVirtualMemorySize * 1024); processes = @($ps) } | ConvertTo-Json -Depth 4 -Compress`);
    try { const j = JSON.parse(out); return { processes: [].concat(j.processes || []), memory: { usedBytes: j.usedBytes, limitBytes: j.limitBytes } }; } catch { return { processes: [], memory: null }; }
  }
  const r = spawnSync('ps', ['-eo', 'pid=,ppid=,etimes=,rss=,comm=,args='], { encoding: 'utf8', timeout: 20000 });
  const now = Date.now();
  const processes = String(r.stdout || '').split('\n').map((l) => l.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s*(.*)$/)).filter(Boolean)
    .map((m) => ({ pid: +m[1], ppid: +m[2], startMs: now - m[3] * 1000, bytes: +m[4] * 1024, name: path.basename(m[5]), cmd: m[6] }));
  let memory = null;
  try {
    const mi = Object.fromEntries(fs.readFileSync('/proc/meminfo', 'utf8').split('\n').map((l) => l.split(/:\s+/)).filter((a) => a[1]).map((a) => [a[0], parseInt(a[1], 10) * 1024]));
    memory = { usedBytes: mi.Committed_AS || 0, limitBytes: mi.CommitLimit || 0 };
  } catch { /* not Linux */ }
  return { processes, memory };
}

export function folderOf(pid, platform = process.platform) {
  if (platform === 'win32') {
    const out = ps(`${PS}\n[Cwd]::Of(${Number(pid)|0})`, 20000).trim();
    return out || null;
  }
  try { return fs.readlinkSync(`/proc/${pid}/cwd`); } catch { return null; }
}

// One tick. Everything outside is injected so a test runs it on a fixture list.
export function tick({ env = process.env, now = Date.now(), machine, folder = folderOf, end = (pid) => process.kill(pid), reread, print = false, selfPid = process.pid } = {}) {
  const settings = readSettings(env);
  const dir = homeDir(env);
  const { processes, memory } = machine || readMachine();
  const { end: list, warn } = decide(processes, now, memory, settings, selfPid);
  const said = [];
  for (const item of list) {
    const rec = recordOf(item, now, folder(item.process.pid));
    if (print) { said.push(sentence(rec, 'ended').replace('ended', 'would end')); continue; }
    // Read again just before: the same process, started at the same time, still over the line.
    if (reread) {
      const again = reread().processes.find((p) => p.pid === item.process.pid && p.startMs === item.process.startMs);
      if (!again) continue;
    }
    fs.mkdirSync(dir, { recursive: true });
    // The record comes first, so a process that cannot be ended is still named.
    appendLog(path.join(dir, 'watchdog.log'), rec);
    let outcome = 'ended';
    try { end(item.process.pid); } catch { outcome = 'refused'; }
    appendLog(path.join(dir, 'watchdog.log'), { at: new Date(now).toISOString(), pid: rec.pid, outcome });
    said.push(sentence(rec, outcome));
  }
  if (!print) {
    fs.mkdirSync(dir, { recursive: true });
    if (said.length) {
      const old = readLines(path.join(dir, 'watchdog-said.txt'));
      fs.writeFileSync(path.join(dir, 'watchdog-said.txt'), [...old, ...said.map((s) => `${Math.floor(now / 1000)}\t${s}`)].slice(-5).join('\n') + '\n');
    }
    const wf = path.join(dir, 'watchdog-warn.txt');
    if (warn) fs.writeFileSync(wf, `${Math.floor(now / 1000)}\t${warnSentence(warn)}\n`);
    else { try { fs.writeFileSync(wf, ''); } catch { /* nothing to clear */ } }
  }
  return { said, warn: warn ? warnSentence(warn) : '' };
}

function readLines(file) { try { return fs.readFileSync(file, 'utf8').split('\n').filter(Boolean); } catch { return []; }
}
function appendLog(file, obj) {
  fs.appendFileSync(file, JSON.stringify(obj) + '\n');
  try { const l = readLines(file); if (l.length > 500) fs.writeFileSync(file, l.slice(-500).join('\n') + '\n'); } catch { /* keep going */ }
}

// A task every minute, once; a later call finds it and does nothing.
export function ensureTask(script, run = (c, a) => spawnSync(c, a, { encoding: 'utf8', windowsHide: true, timeout: 30000 }), platform = process.platform) {
  if (platform !== 'win32') return 'not-windows';
  const name = 'SipNShip watchdog';
  if (run('schtasks', ['/Query', '/TN', name]).status === 0) return 'present';
  const cmd = `"${process.env.SystemRoot || 'C:\\Windows'}\\System32\\conhost.exe" --headless "${process.execPath}" "${script}" --tick`;
  return run('schtasks', ['/Create', '/TN', name, '/TR', cmd, '/SC', 'MINUTE', '/MO', '1', '/F']).status === 0 ? 'created' : 'failed';
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const arg = process.argv[2] || '--tick';
  if (arg === '--ensure-task') console.log(ensureTask(fileURLToPath(import.meta.url)));
  else {
    const r = tick({ print: arg === '--print', reread: readMachine });
    for (const s of r.said) console.log(s);
    if (r.warn) console.log(r.warn);
    if (arg === '--print' && !r.said.length && !r.warn) console.log('nothing to end');
  }
}

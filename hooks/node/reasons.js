'use strict';
// What each check finds in a command, ported from hooks/scripts/lib.sh and
// the two hook libraries. Each takes the command and returns the text the
// shell version printed, or '' for nothing found.
const { words, splitCommands, codeOnly, maskCommand } = require('./text');

const unquote = (s) => s.replace(/["']/g, '');
const base = (s) => s.replace(/.*[\/\\]/, '');
const braces = (c) => c.replace(/{owner}/g, 'OWNER').replace(/{repo}/g, 'REPO');

function deleteReason(command) {
  for (const line of splitCommands(command)) {
    const first = base(line.replace(/[ \t].*/, ''));
    const lower = first.toLowerCase().replace(/\.exe$/, '');
    const rest = line.replace(/^[^ \t]+[ \t]*/, '');
    if (/^(rm|rmdir|del|erase|rd|remove-item|ri)$/.test(lower)) return first;
    if (lower === 'git' && /^clean([ \t]|$)/.test(rest.toLowerCase())) return 'git clean';
    if (/^(cmd|powershell|pwsh)$/.test(lower)) {
      const m = /(^|[ \t"'])(rm|rmdir|del|erase|rd|remove-item|ri)([ \t"']|$)/.exec(rest.toLowerCase());
      if (m) return m[0].replace(/[^a-z-]/g, '');
    }
  }
  return '';
}

function forcePushReason(command) {
  for (const raw of splitCommands(command)) {
    const [t, n] = words(unquote(raw));
    if (t[1] !== 'git') continue;
    let i = 2;
    while (i <= n && /^-/.test(t[i])) {
      if (t[i] === '-C' || t[i] === '-c') i++;
      i++;
    }
    if (t[i] !== 'push') continue;
    for (let j = i + 1; j <= n; j++) {
      const a = t[j];
      if (/^--force($|=)/.test(a) || /^--force-with-lease/.test(a) || a === '--force-if-includes' || /^-[a-zA-Z]*f[a-zA-Z]*$/.test(a) || /^\+/.test(a)) return a;
    }
  }
  return '';
}

const TARGET_FLAG = /^(-k|-t|-g|-m|-n|--grep|--filter|--testNamePattern|--testPathPattern|--test-name-pattern|--run|--tests|--trait|-Dtest=|--match|--name|--spec|--only)/;

function fullSweepReason(command) {
  for (const raw of splitCommands(command)) {
    const [t, n] = words(unquote(raw));
    let i = 1;
    while (i <= n) {
      if (/^(npx|bunx)$/.test(t[i])) { i++; while (i <= n && /^-/.test(t[i])) i++; continue; }
      if ((t[i] === 'pnpm' || t[i] === 'yarn') && (t[i + 1] === 'exec' || t[i + 1] === 'dlx')) { i += 2; continue; }
      if (/^(uv|poetry|pipenv|bundle|hatch|pdm)$/.test(t[i]) && (t[i + 1] === 'run' || t[i + 1] === 'exec')) { i += 2; continue; }
      if (/^python[0-9.]*(\.exe)?$/.test(t[i]) && t[i + 1] === '-m') { i += 2; continue; }
      break;
    }
    if (i > n) continue;
    const runner = base(t[i]).replace(/\.exe$/, '');
    let start = 0, label = '';
    if (/^(npm|yarn|pnpm|bun)$/.test(runner)) {
      let j = i + 1;
      if (t[j] === 'run' || t[j] === 'run-script') j++;
      if (t[j] === 'test' || t[j] === 't' || t[j] === 'tst') { start = j + 1; label = runner + ' ' + t[j]; } else continue;
    } else if (/^(pytest|py\.test|jest|vitest|mocha|ava|tap|rspec|phpunit|ctest|unittest|nose2|karma|playwright|cypress)$/.test(runner)) {
      start = i + 1; label = runner;
    } else if (/^(cargo|go|dotnet|mvn|gradle|gradlew|make|rake|mix|swift|flutter|dart|stack)$/.test(runner) && t[i + 1] === 'test') {
      start = i + 2; label = runner + ' test';
    } else {
      continue;
    }
    let pos = 0;
    for (let j = start; j <= n; j++) {
      const a = t[j];
      if (a === '' || a === '--') continue;
      if (TARGET_FLAG.test(a)) { pos++; continue; }
      if (/^-/.test(a)) continue;
      if (/^(run|watch|test|spec)$/.test(a)) continue;
      if (a === './...' || a === '...' || a === '.') continue;
      pos++;
    }
    if (pos === 0) return label;
  }
  return '';
}

function longCommandReason(command, desc, maxLines = 12, maxChars = 1000) {
  const code = codeOnly(command).replace(/\n+$/, '');
  const lines = code.split('\n').length;
  if (lines > maxLines) return lines + ' lines';
  const chars = Buffer.byteLength(code);
  if (chars > maxChars) return chars + ' characters';
  return desc.replace(/[ \t\r\n]/g, '') === '' ? 'no description' : '';
}

function prCloseReason(command) {
  for (const line of splitCommands(command)) {
    const [t, n] = words(line);
    if (t[1] !== 'gh' || t[2] !== 'pr' || t[3] !== 'close') continue;
    let ok = false;
    for (let i = 4; i <= n; i++) if (t[i] === '--comment' || t[i] === '-c' || /^--comment=/.test(t[i])) ok = true;
    if (!ok) return 'gh pr close';
  }
  return '';
}

function stdinWaitReason(command) {
  const text = maskCommand(command).replace(/&&|\|\||;/g, '\n');
  for (const seg of text.split('\n')) {
    let first = seg;
    const p = first.indexOf('|');
    if (p >= 0) first = first.slice(0, p);
    first = first.replace(/^[ \t\r(]+/, '').replace(/[ \t\r)]+$/, '');
    const [w, m] = words(first);
    if (m < 1 || w[1] === '') continue;
    const c = w[1].replace(/.*\//, '');
    if (!/^(cat|tee|head|tail|wc|sort|read)$/.test(c)) continue;
    let files = 0, fed = false;
    for (let i = 2; i <= m; i++) {
      const a = w[i];
      if (/^</.test(a)) { fed = true; if (a === '<' || a === '<<' || a === '<<<') i++; continue; }
      if (/^[0-9&]*>/.test(a)) { if (/^[0-9&]*>>?$/.test(a)) i++; continue; }
      if (/^-/.test(a)) continue;
      files++;
    }
    if (fed) continue;
    if (c === 'read' || c === 'tee' || files === 0) return first;
  }
  return '';
}

function worktreeAddReason(command) {
  for (const line of splitCommands(command)) {
    const [t, n] = words(line);
    if (t[1] !== 'git') continue;
    let w = 0;
    for (let i = 2; i <= n; i++) {
      if (t[i] === 'worktree' && t[i + 1] === 'add') w = i + 1;
      if (w && i > w && (t[i] === '--detach' || t[i] === '-d')) return 'detached';
    }
  }
  return '';
}

function daemonStopReason(command) {
  if (command.includes('DAEMON_STOP_OK=1')) return '';
  for (const raw of splitCommands(command)) {
    const [t, n] = words(unquote(raw));
    let i = 1;
    while (i <= n && /^(npx|bunx|pnpm|yarn)$/.test(t[i])) i++;
    const c = base(t[i]).replace(/\.(bat|cmd|exe)$/, '');
    if (/^(gradlew|gradle)$/.test(c)) { for (let j = i + 1; j <= n; j++) if (t[j] === '--stop') return c + ' --stop'; }
    if (c === 'nx' && (t[i + 1] === 'reset' || (t[i + 1] === 'daemon' && t[i + 2] === '--stop'))) return 'nx ' + t[i + 1];
    if (c === 'dotnet' && t[i + 1] === 'build-server' && t[i + 2] === 'shutdown') return 'dotnet build-server shutdown';
  }
  return '';
}

function directMergeReason(command) {
  for (const raw of splitCommands(codeOnly(command))) {
    const [t, n] = words(unquote(raw));
    if (t[1] !== 'gh' || t[2] !== 'pr' || t[3] !== 'merge') continue;
    let off = false;
    for (let i = 4; i <= n; i++) if (t[i] === '--disable-auto') off = true;
    if (!off) return 'gh pr merge';
  }
  return '';
}

function batchMergeReason(command) {
  for (const raw of splitCommands(codeOnly(command))) {
    const [t, n] = words(unquote(raw));
    let found = false;
    for (let i = 1; i <= n; i++) if (/(^|[\/\\])merge-queue\.sh$/.test(t[i])) found = true;
    if (!found) continue;
    let prs = 0, flagged = false;
    for (let i = 1; i <= n; i++) {
      if (t[i] === '--batch' || t[i] === '--serial' || t[i] === '--drain') flagged = true;
      else if (/^[0-9]+$/.test(t[i])) prs++;
    }
    if (prs > 2 && !flagged) return String(prs);
  }
  return '';
}

function ghGraphqlReason(command) {
  for (const line of splitCommands(braces(command))) {
    const [t, n] = words(line);
    for (let i = 1; i < n; i++) {
      if (t[i] !== 'gh') continue;
      const s = t[i + 1];
      if (s === 'issue' || s === 'pr' || s === 'project' || s === 'search') return 'gh ' + s + ' ' + t[i + 2];
      if (s === 'api' && t[i + 2] === 'graphql') return 'gh api graphql';
    }
  }
  return '';
}

function stateLabelReason(command) {
  for (const line of splitCommands(braces(command))) {
    const q = unquote(line);
    const [t, n] = words(q);
    if (t[1] === 'gh' && t[2] === 'api') {
      let issues = false, creates = false, found = false;
      for (let j = 3; j <= n; j++) {
        if (/(^|\/)issues(\?.*)?$/.test(t[j])) issues = true;
        if (/^title=/.test(t[j])) creates = true;
        if (t[j] === '--input' || /^labels\[\]=[ \t]*state:/.test(t[j]) || /^labels=.*state:/.test(t[j])) found = true;
      }
      if (issues && creates && !found) return 'gh api .../issues';
    }
    const [u, m] = words(line);
    if (u[1] !== 'gh' || u[2] !== 'issue' || u[3] !== 'create') continue;
    let found = false;
    for (let j = 4; j <= m; j++) if (u[j] === '--web' || u[j] === '-w') found = true;
    let rest = unquote(line);
    for (;;) {
      const mm = /(^|[ \t])(--label=|--label[ \t]+|-l[ \t]*)/.exec(rest);
      if (!mm) break;
      rest = rest.slice(mm.index + mm[0].length);
      let value = rest;
      const d = /[ \t]-/.exec(value);
      if (d) value = value.slice(0, d.index);
      if (/(^|,)[ \t]*state:/.test(value)) found = true;
    }
    if (!found) return 'gh issue create';
  }
  return '';
}

function projectFlagReason(command) {
  for (const line of splitCommands(command)) {
    const [t, n] = words(line);
    if (t[1] !== 'gh' || t[2] !== 'issue' || t[3] !== 'create') continue;
    let found = false;
    for (let j = 4; j <= n; j++) {
      if (t[j] === '--web' || t[j] === '-w' || t[j] === '--project' || t[j] === '-p' || /^--project=/.test(t[j])) found = true;
    }
    if (!found) return 'gh issue create';
  }
  return '';
}

// The issue a command sets to waiting on the owner ('' when none).
function waitingOnOwnerIssue(command) {
  const num = (s) => { s = s.replace(/^#/, '').replace(/.*\/issues\//, ''); return /^[0-9]+$/.test(s) ? s : ''; };
  const waitRe = /state:[ \t]*waiting-on-owner/;
  for (const raw of splitCommands(braces(command))) {
    const line = unquote(raw);
    const [t, n] = words(line);
    const first = base(t[1]);
    const waiting = waitRe.test(line.toLowerCase());
    if (first === 'gh' && t[2] === 'issue' && t[3] === 'edit' && waiting) {
      let rest = line, adds = false;
      for (;;) {
        const m = /(^|[ \t])--add-label(=|[ \t]+)/.exec(rest);
        if (!m) break;
        rest = rest.slice(m.index + m[0].length);
        let value = rest;
        const d = /[ \t]-/.exec(value);
        if (d) value = value.slice(0, d.index);
        if (waitRe.test(value.toLowerCase())) adds = true;
      }
      if (!adds) continue;
      for (let j = 4; j <= n; j++) if (num(t[j]) !== '' && !/^-/.test(t[j - 1])) return num(t[j]);
      continue;
    }
    if (first === 'gh' && t[2] === 'api' && waiting) {
      let get = false;
      for (let j = 3; j <= n; j++) {
        if ((t[j] === '-X' || t[j] === '--method') && /^(GET|DELETE)$/.test(t[j + 1].toUpperCase())) get = true;
        if (/^--method=/.test(t[j]) && /^(GET|DELETE)$/.test(t[j].slice(9).toUpperCase())) get = true;
      }
      if (get) continue;
      for (let j = 3; j <= n; j++) {
        const m = /issues\/[0-9]+\/labels/.exec(t[j]);
        if (m) return m[0].slice(7, m[0].length - 7);
      }
      continue;
    }
    if ((first === 'sh' || first === 'bash') && /(^|\/)state\.sh$/.test(t[2]) && /^[0-9]+$/.test(t[5])) {
      let name = '';
      for (let j = 6; j <= n; j++) name += ' ' + t[j];
      name = name.toLowerCase().replace(/-/g, ' ');
      if (/^ *waiting on (the )?owner *$/.test(name)) return t[5];
    }
  }
  return '';
}

function ruleSwitchReason(command) {
  for (const raw of splitCommands(command)) {
    const line = unquote(raw);
    const [t, n] = words(line);
    const first = base(t[1]).replace(/\.exe$/, '');
    const vars = /(^|[^A-Za-z_])RULES_(OFF|LOCKS)([^A-Za-z_]|$)/.test(line);
    if (first === 'gh' && t[2] === 'variable' && vars && /^(set|delete|remove)$/.test(t[3])) return 'gh variable ' + t[3] + ' RULES_*';
    if (first === 'gh' && t[2] === 'api' && vars && /variables/.test(line)) {
      let write = false;
      for (let i = 3; i <= n; i++) {
        if ((t[i] === '-X' || t[i] === '--method') && t[i + 1].toUpperCase() !== 'GET') write = true;
        if (/^--method=/.test(t[i]) && t[i].slice(9).toUpperCase() !== 'GET') write = true;
        if (/^-f|^-F|^--field|^--raw-field|^--input/.test(t[i])) write = true;
      }
      if (write) return 'gh api (writing RULES_*)';
    }
    if (/rules-off\.txt/.test(line)) {
      const edits = /^(tee|mv|cp|install|truncate|ln|rm)$/.test(first) || (/^(sed|perl)$/.test(first) && / -[a-zA-Z]*i/.test(line));
      if (/>/.test(line) || edits) return '.claude/rules-off.txt';
    }
    for (let i = 1; i < n; i++) {
      if (/(^|[\/\\])rules\.sh$/.test(t[i]) && /^(on|off)$/.test(t[i + 1])) return 'scripts/rules.sh ' + t[i + 1];
    }
  }
  return '';
}

function ruleSwitchPathReason(p) {
  const f = p.replace(/\\/g, '/');
  return f.replace(/.*\//, '') === 'rules-off.txt' ? f : '';
}

module.exports = {
  deleteReason, forcePushReason, fullSweepReason, longCommandReason, prCloseReason, stdinWaitReason,
  worktreeAddReason, daemonStopReason, directMergeReason, batchMergeReason, ghGraphqlReason,
  stateLabelReason, projectFlagReason, waitingOnOwnerIssue, ruleSwitchReason, ruleSwitchPathReason,
};

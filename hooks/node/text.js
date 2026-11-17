'use strict';
// The text readers behind every check, ported from hooks/scripts/lib.sh one
// for one (specs/027-hooks-in-node). Text in, text out: nothing here reads a
// file or starts a process. Where lib.sh leans on awk's habits (splitting on
// blanks, leftmost matches, an empty word past the end), the same habit is kept.

// words(s): awk's split(s, t, /[ \t]+/) as a 1-based array, padded with empty
// words so t[n + 1] reads "" as it does in awk. Returns [t, n].
function words(s) {
  const parts = s === '' ? [] : s.split(/[ \t]+/);
  const t = [''].concat(parts);
  for (let k = 0; k < 8; k++) t.push('');
  return [t, parts.length];
}

// shellValue(s): what $(...) keeps of a string: no trailing newlines.
function shellValue(s) {
  return s.replace(/\n+$/, '');
}

// jsonField(json, key): the string value of the first "KEY", escapes undone;
// '' when the key is missing or its value is not a string.
function jsonField(json, key) {
  const k = '"' + key + '"';
  const i = json.indexOf(k);
  if (i < 0) return '';
  const s = json.slice(i + k.length);
  const m = /^[ \t\r\n]*:[ \t\r\n]*/.exec(s);
  if (!m) return '';
  const v = s.slice(m[0].length);
  if (v[0] !== '"') return '';
  let out = '';
  for (let j = 1; j < v.length; j++) {
    const c = v[j];
    if (c === '\\') {
      j++;
      const d = v[j] === undefined ? '' : v[j];
      if (d === 'n') out += '\n';
      else if (d === 't') out += '\t';
      else if (d === 'r') out += '\r';
      else if (d === 'u') { out += '?'; j += 4; }
      else out += d;
    } else if (c === '"') {
      break;
    } else {
      out += c;
    }
  }
  return out;
}

function opens(s) {
  const a = (s.match(/\(/g) || []).length;
  const b = (s.match(/\)/g) || []).length;
  return a - b;
}

function emit(s) {
  return s.replace(/\$\([^)]*\)/g, 'SUBST').replace(/[ \t]+/g, ' ');
}

// Pass 1 of mask_command: heredoc bodies dropped, continued lines joined.
function dropHeredocs(command) {
  const out = [];
  let inhere = false, dash = false, word = '', held = '', joinheld = false;
  let joining = false, buf = '';
  for (const raw of command.split('\n')) {
    const line = raw.replace(/\r$/, '');
    if (inhere) {
      let check = line;
      if (dash) check = check.replace(/^\t+/, '');
      if (check === word) { inhere = false; if (held !== '') joinheld = true; }
      continue;
    }
    if (joinheld) {
      held = held + ' ' + line;
      if (opens(held) <= 0) { out.push(emit(held)); held = ''; joinheld = false; }
      continue;
    }
    if (joining) buf = (buf + ' ' + line).replace(/[ \t]+/g, ' '); else buf = line;
    joining = false;
    if (/\\$/.test(buf)) { buf = buf.replace(/\\$/, ''); joining = true; continue; }
    const m = /<<-?[ \t]*["']?[A-Za-z_][A-Za-z0-9_]*["']?/.exec(buf);
    if (m) {
      let tok = m[0];
      dash = /^<<-/.test(tok);
      tok = tok.replace(/^<<-?[ \t]*/, '');
      word = tok.replace(/["']/g, '');
      inhere = true;
      if (opens(buf) > 0) { held = buf; continue; }
    }
    out.push(buf);
  }
  if (held !== '') out.push(emit(held));
  if (joining && buf !== '') out.push(buf);
  return out;
}

function maskChar(c) {
  if (c === '\n' || c === '\r') return ' ';
  if (c !== '' && ';&|()`<>'.includes(c)) return '_';
  return c;
}

// Pass 2: inside a quoted string, separators are text, not syntax.
function maskQuoted(s) {
  let out = '', q = '', d = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q === 's') { if (c === "'") q = ''; out += c === "'" ? c : maskChar(c); continue; }
    if (q === 'd') {
      if (c === '\\') { out += c + maskChar(s[i + 1] || ''); i++; continue; }
      if (c === '$' && s[i + 1] === '(') { q = 'c'; d = 1; out += '$('; i++; continue; }
      if (c === '"') { q = ''; out += c; continue; }
      out += maskChar(c); continue;
    }
    if (q === 'c') {
      if (c === '(') d++;
      if (c === ')') { d--; if (d === 0) { q = 'd'; out += c; continue; } }
      out += c; continue;
    }
    if (c === '\\') { out += c + maskChar(s[i + 1] || ''); i++; continue; }
    if (c === "'") { q = 's'; out += c; continue; }
    if (c === '"') { q = 'd'; out += c; continue; }
    out += c;
  }
  return out;
}

// maskCommand(command): the text every check reads before it is cut into
// simple commands (the text mask_command prints, newline last).
function maskCommand(command) {
  const lines = dropHeredocs(command);
  if (lines.length === 0) return '';
  return maskQuoted(lines.join('\n') + '\n');
}

// splitCommands(command): one simple command per entry, leading assignments
// and wrappers such as sudo and env removed.
function splitCommands(command) {
  const text = maskCommand(command).replace(/&&|\|\||;|\||\$\(|`|\(|\)|\{|\}/g, '\n');
  const out = [];
  for (const raw of text.split('\n')) {
    let line = raw.replace(/^[ \t\r]+/, '');
    while (/^([A-Za-z_][A-Za-z0-9_]*=[^ \t]*|sudo|command|exec|nohup|time|env|busybox)[ \t]+/.test(line)) {
      line = line.replace(/^[^ \t]+[ \t]+/, '');
    }
    line = line.replace(/[ \t\r]+$/, '');
    if (line !== '') out.push(line);
  }
  return out;
}

// codeOnly(s): s with the contents of quoted strings dropped (marks kept).
function codeOnly(s) {
  let out = '', q = '';
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q === 's') { if (c === "'") { q = ''; out += c; } continue; }
    if (q === 'd') { if (c === '\\') { i++; continue; } if (c === '"') { q = ''; out += c; } continue; }
    if (c === "'") { q = 's'; out += c; continue; }
    if (c === '"') { q = 'd'; out += c; continue; }
    out += c;
  }
  return out;
}

module.exports = { words, shellValue, jsonField, maskCommand, splitCommands, codeOnly };

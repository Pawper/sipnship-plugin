'use strict';
/**
 * Where each design token is used, and the literal colours and sizes the
 * design check finds, worked out from a project's own files and sent with a
 * session's brief as its `design` field (names and values only, never code).
 * The tokens map reads it; until it arrives each token says "Where it is used
 * shows after your agent's next session."
 *
 * Token names are the ones the map shows: a key (`terracotta`, `label`), a
 * block's value as `block.prop`, a part as `parts.<key>`. A screen is the
 * name a line of scripts/ci/mocks.txt gives its UI files, else the file's
 * own name. Nothing here runs the project or reads outside it.
 */
const fs = require('fs');
const path = require('path');
const cp = require('child_process');

const TOKENS_MAX = 2000;
const LITERALS_MAX = 100;
const LIST_MAX = 60;
const FILE_MAX_BYTES = 400 * 1024;
const DEFAULT_GLOBS = ['src/**/*.tsx', 'src/**/*.ts', 'src/**/*.css', 'android/**/*.kt', 'ios/**/*.swift'];

const readText = (file) => { try { return fs.readFileSync(file, 'utf8').replace(/\r/g, ''); } catch { return ''; } };
const lines = (text) => text.split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('#'));

/** A git-style pathspec glob as a regular expression: `*` reads across folders. */
function globRe(glob) {
  const body = glob.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*\*\//g, '\u0000').replace(/\*\*|\*/g, '.*').replace(/\u0000/g, '(?:.*/)?');
  return new RegExp(`^${body}$`);
}

/** The pointer `{group.key}` as the key it names. */
const pointer = (v) => (typeof v === 'string' ? (v.match(/^\{[A-Za-z]+\.([A-Za-z0-9.]+)\}$/) || [])[1] : undefined);
const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);

/** Every token's name with the values a literal may be near, and what each part points at. */
function readTokens(file) {
  const names = [];
  const colours = [];
  const sizes = [];
  const parts = {};
  const push = (name, extra = {}) => names.push({ name, ...extra });
  for (const g of file.ground || []) if (g && g.key) { push(g.key); colours.push({ name: g.key, hexes: [g.hex, g.dark].filter(Boolean) }); }
  for (const a of file.accents || []) if (a && a.key) { push(a.key); colours.push({ name: a.key, hexes: (a.stops || []).filter((s) => typeof s === 'string') }); }
  for (const g of file.gradients || []) if (g && g.key) push(g.key);
  for (const r of (file.type && file.type.roles) || []) if (r && r.key) push(r.key);
  const raw = {};
  for (const group of ['spacing', 'radii', 'iconSizes']) for (const [k, t] of Object.entries(file[group] || {})) if (t && typeof t === 'object') raw[k] = t.$value;
  const px = (k, depth = 0) => { const v = raw[k]; const at = pointer(v); return at && depth < 6 ? px(at, depth + 1) : typeof v === 'number' ? v : undefined; };
  for (const group of ['spacing', 'radii', 'shadows', 'iconSizes']) {
    for (const [k, t] of Object.entries(file[group] || {})) {
      if (!t || typeof t !== 'object' || k.startsWith('_')) continue;
      push(k);
      const n = px(k);
      if (n !== undefined) sizes.push({ name: k, px: n });
    }
  }
  for (const [block, props] of Object.entries(file.blocks || {})) {
    if (block.startsWith('_') || !props || typeof props !== 'object') continue;
    for (const [k, t] of Object.entries(props)) {
      if (!t || typeof t !== 'object' || k.startsWith('_')) continue;
      push(`${block}.${k}`, { block, prop: k });
      if (typeof t.$value === 'number') sizes.push({ name: `${block}.${k}`, px: t.$value });
    }
  }
  for (const [key, p] of Object.entries(file.parts || {})) {
    if (!p || typeof p !== 'object') continue;
    parts[key] = [...new Set(Object.entries(p).flatMap(([prop, t]) => (prop.startsWith('$') || !t ? [] : [pointer(t.$value)].filter(Boolean))))];
  }
  return { names, colours, sizes, parts };
}

/** The UI files: the design check's globs, git's file list, never the generated or vendored ones. */
function uiFiles(root, file) {
  const listed = lines(readText(path.join(root, 'scripts/ci/design-ui.txt')));
  const res = (listed.length ? listed : DEFAULT_GLOBS).map(globRe);
  const o = file.outputs || {};
  const generated = new Set([o.ts, o.css, o.kotlin && o.kotlin.path, typeof o.swift === 'string' ? o.swift : o.swift && o.swift.path, o.copyTs, o.copyKotlin && o.copyKotlin.path, typeof o.copySwift === 'string' ? o.copySwift : o.copySwift && o.copySwift.path].filter(Boolean));
  let all = [];
  try { all = cp.execFileSync('git', ['ls-files'], { cwd: root, encoding: 'utf8', timeout: 5000, maxBuffer: 16 * 1024 * 1024 }).split('\n'); } catch { return []; }
  return all.map((f) => f.trim()).filter((f) => f && !f.startsWith('design/') && !f.includes('node_modules/') && !f.includes('/build/') && !generated.has(f) && res.some((re) => re.test(f)));
}

/** File to screen name: the first mocks.txt line whose UI glob matches, else the file's own name. */
function screenNamer(root) {
  const entries = lines(readText(path.join(root, 'scripts/ci/mocks.txt')))
    .map((l) => l.split(/\s+/))
    .filter((w) => w.length >= 2 && !['unmocked', 'generator'].includes(w[0]) && !w[0].endsWith(':'))
    .map((w) => ({ name: w[0], re: globRe(w[1]) }));
  return (f) => (entries.find((e) => e.re.test(f)) || { name: path.basename(f).replace(/\.[^.]+$/, '') }).name;
}

const isComment = (l) => /^(\/\/|\/\*|\*|#)/.test(l.trim()) || l.includes('@media');

/** The colour as three numbers, or undefined. */
function rgb(hex) {
  let h = String(hex).replace(/^#|^0x(ff)?/i, '');
  if (h.length === 3 || h.length === 4) h = h.slice(0, 3).split('').map((c) => c + c).join('');
  return /^[0-9a-f]{6}/i.test(h) ? [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16)) : undefined;
}

/** The nearest token to a literal: a colour within a small distance, a size of the same value. */
function nearest(value, tokens) {
  const c = rgb(value);
  if (c) {
    let best;
    for (const t of tokens.colours) for (const h of t.hexes) {
      const o = rgb(h);
      if (!o) continue;
      const d = Math.hypot(c[0] - o[0], c[1] - o[1], c[2] - o[2]);
      if (d <= 24 && (!best || d < best.d)) best = { d, name: t.name };
    }
    return best && best.name;
  }
  const n = parseFloat(value);
  const t = tokens.sizes.find((s) => s.px === n);
  return t && t.name;
}

/** The literal colours and sizes in one file's lines, as the design check reads them. */
function literalsOf(text, allow) {
  const out = [];
  for (const line of text.split('\n')) {
    if (isComment(line) || (allow && allow.test(line))) continue;
    for (const m of line.matchAll(/#[0-9a-fA-F]{3}(?:[0-9a-fA-F]{3})?(?:[0-9a-fA-F]{2})?(?![0-9a-zA-Z_-])|0[xX][fF][fF][0-9a-fA-F]{6}/g)) out.push(m[0].toUpperCase().replace(/^0XFF/, '#'));
    for (const m of line.matchAll(/(?<![A-Za-z0-9_.-])(\d+(?:\.\d+)?)(px|dp|sp)(?![A-Za-z0-9_])/g)) {
      const n = Number(m[1]);
      if (n !== 0 && n !== 0.5 && n !== 1) out.push(`${m[1]}${m[2]}`);
    }
  }
  return out;
}

/** Whether a file names a token, in a code position (a name in prose does not count). */
function names(text) {
  const code = text.split('\n').filter((l) => !isComment(l)).join('\n');
  const words = new Set();
  for (const m of code.matchAll(/(?<=[.\-'"`([{$:/=])([A-Za-z][A-Za-z0-9]*)(?![A-Za-z0-9_])/g)) words.add(m[1]);
  const any = new Set(code.match(/[A-Za-z][A-Za-z0-9]*/g) || []);
  return { code, words, any };
}
const uses = (seen, t) => (t.block
  ? seen.code.includes(`${t.block}.${t.prop}`) || seen.code.includes(`${t.block}-${t.prop}`) || seen.words.has(t.block + cap(t.prop))
  : seen.words.has(t.name) || seen.words.has(cap(t.name)));

/**
 * The brief's design field for the project at ROOT, or undefined when it has
 * no tokens file. Never throws.
 */
function designUse({ root = process.cwd(), now = new Date() } = {}) {
  try {
    const raw = readText(path.join(root, 'design/tokens.json'));
    if (!raw) return undefined;
    const file = JSON.parse(raw);
    const tokens = readTokens(file);
    const screenOf = screenNamer(root);
    const allowText = lines(readText(path.join(root, 'scripts/ci/design-allow.txt'))).join('|');
    const allow = allowText ? new RegExp(allowText) : undefined;
    const reach = new Map();
    const reachOf = (name) => { if (!reach.has(name)) reach.set(name, { parts: new Set(), screens: new Set() }); return reach.get(name); };
    for (const [key, pointed] of Object.entries(tokens.parts)) for (const p of pointed) reachOf(p).parts.add(key);
    const literals = [];
    const seenLiteral = new Set();
    for (const f of uiFiles(root, file)) {
      let text = '';
      try { if (fs.statSync(path.join(root, f)).size <= FILE_MAX_BYTES) text = readText(path.join(root, f)); } catch { /* unreadable: skipped */ }
      if (!text) continue;
      const screen = screenOf(f);
      const seen = names(text);
      for (const t of tokens.names) if (uses(seen, t)) reachOf(t.name).screens.add(screen);
      for (const key of Object.keys(tokens.parts)) if (seen.any.has(key)) reachOf(`parts.${key}`).screens.add(screen);
      for (const value of literalsOf(text, allow)) {
        const id = `${value}\t${screen}`;
        if (seenLiteral.has(id) || literals.length >= LITERALS_MAX) continue;
        seenLiteral.add(id);
        const near = nearest(value, tokens);
        literals.push({ value, screen, ...(near ? { near } : {}) });
      }
    }
    const out = {};
    for (const [name, r] of [...reach].slice(0, TOKENS_MAX)) {
      if (r.parts.size || r.screens.size) out[name] = { parts: [...r.parts].slice(0, LIST_MAX), screens: [...r.screens].sort().slice(0, LIST_MAX) };
    }
    return { at: now.toISOString(), tokens: out, literals };
  } catch {
    return undefined;
  }
}

module.exports = { designUse, literalsOf, readTokens, globRe };

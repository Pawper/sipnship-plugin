#!/usr/bin/env node
// A screen's mock and its build, side by side. Renders the mock (a file) and
// the built screen (a URL) at the mock's viewport with the machine's own
// browser in headless mode, light and dark, composes one PNG (mock left,
// build right, light above dark), and prints the share of pixels that differ
// by more than 16 in any channel:
//   NAME diff=0.0421 threshold=0.05 flagged=no path/to/NAME.png
// No dependencies: PNG is read and written with node's zlib.
// Usage: node scripts/design/screens-diff.mjs NAME MOCK_FILE BUILT_URL OUT_DIR
//          [--viewport WxH] [--threshold 0.05] [--light-only]
//    or: node scripts/design/screens-diff.mjs --browser   (the browser it would use)
// BROWSER_PATH names the browser when it is not in a standard place. The
// single renders and the browser profile stay in OUT_DIR/.render-NAME.
// Exit 0 when rendered (flagged or not), 2 when it could not render.
import fs from 'node:fs'; import path from 'node:path'; import zlib from 'node:zlib';
import os from 'node:os'; import { execFileSync } from 'node:child_process'; import { pathToFileURL } from 'node:url';

export function findBrowser(env = process.env) {
  if (env.BROWSER_PATH) return fs.existsSync(env.BROWSER_PATH) ? env.BROWSER_PATH : null;
  const pf = [env.ProgramFiles || 'C:/Program Files', env['ProgramFiles(x86)'] || 'C:/Program Files (x86)'];
  const c = [...pf.map(p => `${p}/Google/Chrome/Application/chrome.exe`), ...pf.map(p => `${p}/Microsoft/Edge/Application/msedge.exe`),
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge'];
  const pw = path.join(env.LOCALAPPDATA || path.join(os.homedir(), '.cache'), 'ms-playwright');
  try { for (const d of fs.readdirSync(pw).filter(d => d.startsWith('chromium-')).sort().reverse())
    c.push(path.join(pw, d, 'chrome-win', 'chrome.exe'), path.join(pw, d, 'chrome-win64', 'chrome.exe'), path.join(pw, d, 'chrome-linux', 'chrome')); } catch {}
  for (const dir of (env.PATH || '').split(path.delimiter)) for (const n of ['google-chrome', 'chromium', 'chromium-browser', 'chrome', 'msedge', 'microsoft-edge'])
    c.push(path.join(dir, n), path.join(dir, n + '.exe'));
  return c.find(p => { try { return fs.statSync(p).isFile(); } catch { return false; } }) || null;
}

// The viewport a mock asks for: data-viewport="390x844", else a viewport
// meta's width (and height); 390x844 by default.
export function mockViewport(html) {
  const d = /data-viewport\s*=\s*["']?(\d+)x(\d+)/i.exec(html); if (d) return [+d[1], +d[2]];
  const m = /<meta[^>]+name\s*=\s*["']viewport["'][^>]*>/i.exec(html);
  const w = m && /width\s*=\s*(\d+)/i.exec(m[0]), h = m && /height\s*=\s*(\d+)/i.exec(m[0]);
  return [w ? +w[1] : 390, h ? +h[1] : 844];
}

export function decodePng(buf) {
  if (buf.readUInt32BE(0) !== 0x89504e47) throw new Error('not a PNG');
  let o = 8, w, h, type; const idat = [];
  while (o < buf.length) {
    const len = buf.readUInt32BE(o), t = buf.toString('latin1', o + 4, o + 8), d = buf.subarray(o + 8, o + 8 + len);
    if (t === 'IHDR') { w = d.readUInt32BE(0); h = d.readUInt32BE(4); type = d[9];
      if (d[8] !== 8 || (type !== 2 && type !== 6) || d[12]) throw new Error('only 8-bit RGB or RGBA, not interlaced'); }
    if (t === 'IDAT') idat.push(d); if (t === 'IEND') break; o += 12 + len;
  }
  const bpp = type === 6 ? 4 : 3, stride = w * bpp, raw = zlib.inflateSync(Buffer.concat(idat));
  const px = Buffer.alloc(w * h * 4), prev = Buffer.alloc(stride), cur = Buffer.alloc(stride);
  for (let y = 0; y < h; y++) {
    const f = raw[y * (stride + 1)], s = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    for (let i = 0; i < stride; i++) {
      const a = i >= bpp ? cur[i - bpp] : 0, b = prev[i], c = i >= bpp ? prev[i - bpp] : 0;
      let p = 0;
      if (f === 1) p = a; else if (f === 2) p = b; else if (f === 3) p = (a + b) >> 1;
      else if (f === 4) { const q = a + b - c, pa = Math.abs(q - a), pb = Math.abs(q - b), pc = Math.abs(q - c); p = pa <= pb && pa <= pc ? a : pb <= pc ? b : c; }
      cur[i] = (s[i] + p) & 255;
    }
    for (let x = 0; x < w; x++) for (let k = 0; k < 4; k++) px[(y * w + x) * 4 + k] = k < bpp ? cur[x * bpp + k] : 255;
    cur.copy(prev);
  }
  return { w, h, px };
}

const crcT = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
const crc = b => { let c = 0xffffffff; for (const x of b) c = crcT[(c ^ x) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
function chunk(t, d) { const l = Buffer.alloc(4), c = Buffer.alloc(4), td = Buffer.concat([Buffer.from(t, 'latin1'), d]); l.writeUInt32BE(d.length); c.writeUInt32BE(crc(td)); return Buffer.concat([l, td, c]); }
export function encodePng({ w, h, px }) {
  const raw = Buffer.alloc(h * (w * 4 + 1));
  for (let y = 0; y < h; y++) px.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4);
  const ih = Buffer.alloc(13); ih.writeUInt32BE(w, 0); ih.writeUInt32BE(h, 4); ih[8] = 8; ih[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ih), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}

// The share of pixels where any channel differs by more than tol.
export function diffShare(a, b, tol = 16) {
  let n = 0; const total = a.w * a.h;
  for (let i = 0; i < total; i++) for (let k = 0; k < 3; k++) if (Math.abs(a.px[i * 4 + k] - b.px[i * 4 + k]) > tol) { n++; break; }
  return total ? n / total : 0;
}

// Rows of images on one grey canvas, 8 pixels apart.
export function compose(rows, gap = 8) {
  const w = Math.max(...rows.map(r => r.reduce((s, i) => s + i.w, 0) + gap * (r.length - 1)));
  const h = rows.reduce((s, r) => s + Math.max(...r.map(i => i.h)), 0) + gap * (rows.length - 1);
  const px = Buffer.alloc(w * h * 4, 128); let y0 = 0;
  for (const r of rows) { let x0 = 0;
    for (const im of r) { for (let y = 0; y < im.h; y++) im.px.copy(px, ((y0 + y) * w + x0) * 4, y * im.w * 4, (y + 1) * im.w * 4); x0 += im.w + gap; }
    y0 += Math.max(...r.map(i => i.h)) + gap; }
  return { w, h, px };
}

function render(browser, url, [w, h], dark, file, profile) {
  const args = ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run', '--no-default-browser-check',
    `--user-data-dir=${profile}`, `--window-size=${w},${h}`, `--screenshot=${file}`,
    // prefers-color-scheme, set both ways: headless follows the machine's
    // own theme otherwise, so "light" came out dark on a dark desktop
    `--blink-settings=preferredColorScheme=${dark ? 0 : 1}`];
  execFileSync(browser, [...args, url], { stdio: 'ignore', timeout: 60000 });
  return decodePng(fs.readFileSync(file));
}

function main(argv) {
  if (argv[0] === '--browser') { const b = findBrowser(); if (b) console.log(b); return b ? 0 : 2; }
  const pos = [], opt = {};
  for (let i = 0; i < argv.length; i++) if (argv[i].startsWith('--')) { const k = argv[i].slice(2); opt[k] = k === 'light-only' ? true : argv[++i]; } else pos.push(argv[i]);
  const [name, mock, built, out] = pos;
  if (!out) { console.error('Usage: node screens-diff.mjs NAME MOCK_FILE BUILT_URL OUT_DIR [--viewport WxH] [--threshold 0.05] [--light-only]'); return 2; }
  const browser = findBrowser(); if (!browser) { console.error('No browser found: set BROWSER_PATH to Chrome, Edge or Chromium.'); return 2; }
  const vp = opt.viewport ? opt.viewport.split('x').map(Number) : mockViewport(fs.readFileSync(mock, 'utf8'));
  const threshold = Number(opt.threshold ?? 0.05), work = path.join(out, `.render-${name}`);
  fs.mkdirSync(work, { recursive: true });
  try {
    const rows = []; let diff = 0, n = 0;
    for (const dark of opt['light-only'] ? [false] : [false, true]) {
      const s = dark ? 'dark' : 'light', profile = path.resolve(work, 'profile');
      const m = render(browser, pathToFileURL(path.resolve(mock)).href, vp, dark, path.resolve(work, `mock-${s}.png`), profile);
      const b = render(browser, built, vp, dark, path.resolve(work, `build-${s}.png`), profile);
      if (m.w !== b.w || m.h !== b.h) throw new Error(`the two renders differ in size (${m.w}x${m.h}, ${b.w}x${b.h})`);
      diff += diffShare(m, b) * m.w * m.h; n += m.w * m.h; rows.push([m, b]);
    }
    const share = n ? diff / n : 0, file = path.join(out, `${name}.png`);
    fs.writeFileSync(file, encodePng(compose(rows)));
    console.log(`${name} diff=${share.toFixed(4)} threshold=${threshold} flagged=${share > threshold ? 'yes' : 'no'} ${file.split(path.sep).join('/')}`);
    return 0;
  } catch (e) { console.error(`${name}: could not render: ${e.message}`); return 2; }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) process.exitCode = main(process.argv.slice(2));

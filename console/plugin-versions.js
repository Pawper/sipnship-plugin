'use strict';
/**
 * The plugin's three versions, as the brief reports them to the service (spec
 * 006): the copy running here, the latest release the session brief last read
 * and the repository's own plugin folder. Local files only: nothing is
 * fetched here, and a version that is not known is left out.
 */
const fs = require('fs');
const os = require('os');
const path = require('path');

const VERSION = /^\d{1,4}\.\d{1,5}\.\d{1,6}$/;

/** The "version" of a plugin.json file, or undefined when it is missing or not a version. */
function versionOf(file) {
  try {
    const v = JSON.parse(fs.readFileSync(file, 'utf8')).version;
    return typeof v === 'string' && VERSION.test(v) ? v : undefined;
  } catch { return undefined; }
}

/**
 * The released version the session brief's background read cached: the
 * newest "plugin-versions" file under the brief cache holds "released=X ...".
 */
function releasedFrom(home) {
  const dir = path.join(home, 'brief-cache');
  let best;
  let bestAt = -1;
  try {
    for (const name of fs.readdirSync(dir)) {
      const file = path.join(dir, name, 'plugin-versions');
      try {
        const at = fs.statSync(file).mtimeMs;
        if (at > bestAt) { bestAt = at; best = file; }
      } catch { /* no file in this folder */ }
    }
    const m = best && /released=([0-9.]+)/.exec(fs.readFileSync(best, 'utf8'));
    return m && VERSION.test(m[1]) ? m[1] : undefined;
  } catch { return undefined; }
}

/**
 * How many of this project's shipped files the last sync report found older than the plugin's, and how many the builder
 * changed (#2703). Read from what that report kept inside .git, and only while it still holds: the same plugin version and
 * the same commit. Nothing is run beyond one git call; when it cannot tell, nothing is said. "beyondList" carries through
 * unchanged: the sync set it when the installed plugin had no known-hash list to judge by at all, so older and edited are
 * not a count to trust, only the plain fact that the project is behind.
 */
function shippedFrom(root, installed) {
  try {
    const kept = JSON.parse(fs.readFileSync(path.join(root, '.git', 'sipnship-shipped.json'), 'utf8'));
    if (!installed || kept.version !== installed) return undefined;
    const head = require('child_process').execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, timeout: 3000, encoding: 'utf8' }).trim();
    if (!head || kept.head !== head) return undefined;
    const whole = (n) => Number.isInteger(n) && n >= 0 && n < 100000;
    if (!whole(kept.older) || !whole(kept.edited)) return undefined;
    return kept.beyondList === true ? { older: kept.older, edited: kept.edited, beyondList: true } : { older: kept.older, edited: kept.edited };
  } catch { return undefined; }
}

/** {installed, released, repository} for this machine and project, or undefined when none is known. */
function read({ root = process.cwd(), env = process.env } = {}) {
  const home = env.SIPNSHIP_HOME || path.join(os.homedir(), '.sipnship');
  const installed = versionOf(path.join(__dirname, '..', '.claude-plugin', 'plugin.json'));
  const repository = versionOf(path.join(root, 'plugin', '.claude-plugin', 'plugin.json'));
  const released = releasedFrom(home);
  const out = {};
  const shipped = shippedFrom(root, installed);
  if (shipped) out.shipped = shipped;
  if (installed) out.installed = installed;
  if (released) out.released = released;
  if (repository) out.repository = repository;
  return Object.keys(out).length ? out : undefined;
}

module.exports = { read, versionOf, releasedFrom, shippedFrom };

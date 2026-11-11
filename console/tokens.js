'use strict';
// The repository tokens this machine holds: one per repository, in
// ~/.sipnship/tokens.json (or $SIPNSHIP_HOME/tokens.json), outside every
// repository so no worktree, copy or commit can carry one. Keyed by the
// repository's GitHub id. Readable by this user only. Nothing here prints a
// token.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

function home(env = process.env) {
  return env.SIPNSHIP_HOME || path.join(env.HOME || env.USERPROFILE || os.homedir(), '.sipnship');
}

function file(env = process.env) {
  return path.join(home(env), 'tokens.json');
}

function looksLikeToken(t) {
  return typeof t === 'string' && /^sns_repo_[A-Za-z0-9_-]{43}$/.test(t);
}

/** The whole store; an empty one when the file is missing or unreadable. */
function read(env = process.env) {
  try {
    const raw = JSON.parse(fs.readFileSync(file(env), 'utf8'));
    if (raw && typeof raw === 'object' && raw.repos && typeof raw.repos === 'object') return { version: 1, repos: raw.repos };
  } catch { /* none yet */ }
  return { version: 1, repos: {} };
}

function write(store, env = process.env) {
  const dir = home(env);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  // A folder made earlier by something wider is tightened too (macOS and Linux).
  try { fs.chmodSync(dir, 0o700); } catch { /* the platform has no such mode */ }
  const f = file(env);
  const tmp = `${f}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(store, null, 2) + '\n', { mode: 0o600 });
  fs.renameSync(tmp, f);
  try { fs.chmodSync(f, 0o600); } catch { /* the platform has no such mode */ }
  ownerOnlyOnWindows(f, env);
}

/**
 * On Windows a mode means little: the file inherits what its folder allows. Drop the inherited
 * access and give this user alone full control, so nobody else on the machine can read the token.
 * Best effort; a machine without icacls keeps the profile folder's own access.
 */
function ownerOnlyOnWindows(f, env = process.env, run = execFileSync, platform = process.platform) {
  if (platform !== 'win32') return false;
  const user = env.USERNAME;
  if (!user) return false;
  try {
    run('icacls', [f, '/inheritance:r', '/grant:r', `${user}:F`], { stdio: 'ignore', timeout: 10000 });
    return true;
  } catch { return false; }
}

/** Keep a token for one repository, replacing the one it had. */
function put(entry, env = process.env) {
  if (!looksLikeToken(entry.token)) throw new Error('That is not a SipNShip repository token.');
  if (!Number.isInteger(entry.repoId) || entry.repoId <= 0) throw new Error('The repository id is missing.');
  const store = read(env);
  store.repos[String(entry.repoId)] = {
    fullName: entry.fullName,
    token: entry.token,
    machine: entry.machine,
    connectedAt: entry.connectedAt || new Date().toISOString(),
  };
  write(store, env);
}

/** The entry for a repository, by its id or its owner/name; undefined when there is none. */
function find(key, env = process.env) {
  if (key === undefined || key === null || key === '') return undefined;
  const store = read(env);
  if (/^\d+$/.test(String(key)) && store.repos[String(key)]) return { repoId: Number(key), ...store.repos[String(key)] };
  const lower = String(key).toLowerCase();
  for (const [id, e] of Object.entries(store.repos)) {
    if (e && typeof e.fullName === 'string' && e.fullName.toLowerCase() === lower) return { repoId: Number(id), ...e };
  }
  return undefined;
}

/** Forget a repository's token on this machine. True when there was one. */
function remove(repoId, env = process.env) {
  const store = read(env);
  if (!store.repos[String(repoId)]) return false;
  delete store.repos[String(repoId)];
  write(store, env);
  return true;
}

/** owner/name from a git remote URL; undefined when it is not GitHub's. */
function repoFromRemote(url) {
  const m = String(url || '').trim().match(/github\.com[:/]([^/\s]+)\/([^/\s]+?)(?:\.git)?\/?$/);
  return m ? `${m[1]}/${m[2]}` : undefined;
}

module.exports = { ownerOnlyOnWindows, home, file, read, write, put, find, remove, looksLikeToken, repoFromRemote };

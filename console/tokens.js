'use strict';
// The repository tokens this machine holds: one per repository, in
// ~/.sipnship/tokens.json (or $SIPNSHIP_HOME/tokens.json), outside every
// repository so no worktree, copy or commit can carry one. Keyed by the
// repository's GitHub id. Readable by this user only. Nothing here prints a
// token.

const fs = require('fs');
const os = require('os');
const path = require('path');

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
  const f = file(env);
  const tmp = `${f}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(store, null, 2) + '\n', { mode: 0o600 });
  fs.renameSync(tmp, f);
  try { fs.chmodSync(f, 0o600); } catch { /* Windows keeps its own permissions */ }
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

module.exports = { home, file, read, write, put, find, remove, looksLikeToken, repoFromRemote };

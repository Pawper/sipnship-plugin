'use strict';
// The rules a request is checked by on this machine, the same as the
// service's (a test keeps the two equal): the kinds, each kind's one
// parameter, what this machine can do, and the facts a step may carry.
// A request is data the service handed over, never an instruction: it is
// a kind from this list and a parameter that passes its rule, or it is
// refused.

const { RULES } = require('./permissions');

const KINDS = ['add-runner', 'remove-runner', 'grant-permissions', 'run-migration', 'deploy', 'scan-skip', 'scan-again'];
// Kinds that end in Windows' own administrator prompt, and the kinds that only change a Windows machine.
const ELEVATED = ['add-runner', 'remove-runner', 'scan-skip', 'scan-again'];
const WINDOWS_ONLY = ELEVATED;
const PERMISSION_IDS = RULES.map((r) => r.id);
const SCAN_FOLDERS = ['runners', 'git', 'node', 'packages'];
const EXPIRE_MINUTES = 30;

const RUNNER_NAME = /^[a-z][a-z0-9-]{1,30}[a-z0-9]$/;
// How many runners one request may add: the script's own limit. A name starts with a letter, so a count never reads as one.
const RUNNER_COUNT = /^([1-9]|1[0-9]|20)$/;

// paramRule(kind, raw): the parameter in its stored form, or undefined when the rule refuses it.
function paramRule(kind, raw) {
  const s = typeof raw === 'string' ? raw.trim() : raw === undefined || raw === null ? '' : String(raw);
  if (kind === 'add-runner') return RUNNER_NAME.test(s) || RUNNER_COUNT.test(s) ? s : undefined;
  if (kind === 'remove-runner') return RUNNER_NAME.test(s) ? s : undefined;
  if (kind === 'grant-permissions') {
    const ids = s.split(',').map((x) => x.trim()).filter(Boolean);
    if (!ids.length || ids.some((i) => !PERMISSION_IDS.includes(i))) return undefined;
    return PERMISSION_IDS.filter((i) => ids.includes(i)).join(',');
  }
  if (kind === 'run-migration') return s === 'main' || /^[1-9]\d{0,6}$/.test(s) ? s : undefined;
  if (KINDS.includes(kind)) return s === '' ? '' : undefined;
  return undefined;
}

// canKinds(facts): the kinds this machine's listener carries out, from what it found when it started.
function canKinds(f) {
  if (!f || !f.ghAs) return [];
  return KINDS.filter((k) => {
    if (WINDOWS_ONLY.includes(k) && !f.windows) return false;
    if ((k === 'add-runner' || k === 'remove-runner') && !f.admin) return false;
    if ((k === 'scan-skip' || k === 'scan-again') && !f.antivirus) return false;
    return true;
  });
}

// stepFacts(kind, facts): only the kind's own facts, so no log or command text can ride along.
function stepFacts(kind, f) {
  const out = {};
  if (!f || typeof f !== 'object') return out;
  const t = (k) => (typeof f[k] === 'string' || typeof f[k] === 'number' ? String(f[k]) : '');
  if ((kind === 'add-runner' || kind === 'remove-runner') && RUNNER_NAME.test(t('runner'))) out.runner = t('runner');
  if (kind === 'grant-permissions' && /^[1-9]\d{0,6}$/.test(t('pr'))) out.pr = t('pr');
  if ((kind === 'run-migration' || kind === 'deploy') && /^\d{1,15}$/.test(t('run'))) out.run = t('run');
  if (kind === 'scan-skip' || kind === 'scan-again') {
    const ids = t('folders').split(',').filter((i) => SCAN_FOLDERS.includes(i));
    if (ids.length) out.folders = ids.join(',');
  }
  return out;
}

// One line of the service's read: id, kind, param, asked_by, approved_by, approved_at, tab separated.
function parseLines(text) {
  return String(text || '').split('\n').filter(Boolean).map((l) => {
    const [id, kind, param = '', askedBy = '', approvedBy = '', approvedAt = ''] = l.split('\t');
    return { id, kind, param, askedBy, approvedBy, approvedAt };
  });
}

// refusal(req, { ghAs, can, now }): why this request must not run, as an outcome word, or null.
function refusal(req, { ghAs, can, now = Date.now() }) {
  if (!/^[A-Za-z0-9-]{1,64}$/.test(req.id || '')) return 'refused';
  if (!KINDS.includes(req.kind) || !can.includes(req.kind)) return 'refused';
  if (paramRule(req.kind, req.param) !== req.param) return 'refused';
  if (!req.approvedBy || !req.approvedAt) return 'refused';
  const t = Date.parse(req.approvedAt);
  if (Number.isNaN(t) || now - t >= EXPIRE_MINUTES * 60000 || t - now > 5 * 60000) return 'refused';
  if (!ghAs || req.approvedBy.toLowerCase() !== ghAs.toLowerCase()) return 'refused-person';
  return null;
}

module.exports = { KINDS, ELEVATED, WINDOWS_ONLY, PERMISSION_IDS, SCAN_FOLDERS, EXPIRE_MINUTES, paramRule, canKinds, stepFacts, parseLines, refusal };

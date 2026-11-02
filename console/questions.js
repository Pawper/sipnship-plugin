'use strict';
// The builder's questions for a working agent, carried on the brief road (specs/007-mote, "Why").
// A brief's reply may hold questions the dashboard's Mote recorded about a card. This module keeps them
// on this machine, hands each to the agent session that worked on that card (or, when that session is
// gone, to the next one that starts), and keeps the agent's one-sentence answers until the next brief
// carries them back. Names and plain words only; a file that cannot be read or written is never an error.

const fs = require('fs');
const path = require('path');
const tokens = require('./tokens');

const KEPT_MS = 24 * 60 * 60 * 1000;
const ANSWER_MAX = 100;
const INBOX_MAX = 20;

function dir(env, repoId) {
  return path.join(tokens.home(env), 'questions', String(repoId));
}
function readJson(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}
function writeJson(file, value) {
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(value) + '\n');
  } catch { /* never stops the session */ }
}
const inboxFile = (env, repoId) => path.join(dir(env, repoId), 'inbox.json');
const outboxFile = (env, repoId) => path.join(dir(env, repoId), 'outbox.json');

/** What is kept: questions not yet answered, and the ids already answered so a repeat is not asked again. */
function load(env, repoId, now = Date.now()) {
  const kept = readJson(inboxFile(env, repoId), {});
  const all = Array.isArray(kept.questions) ? kept.questions : [];
  const open = all.filter((q) => q && q.id && now - Date.parse(q.askedAt) < KEPT_MS);
  return { questions: open, letGo: all.length - open.length, answered: (Array.isArray(kept.answered) ? kept.answered : []).slice(-50) };
}
const save = (env, repoId, s) => writeJson(inboxFile(env, repoId), { questions: s.questions, answered: s.answered });

/**
 * The session that worked on a card: the one in the recent sample whose issues, branch or folder name the card's
 * number. Cards are named like pull:187 or issue:649. None when no session in the sample does, which is "gone".
 */
function workedOn(card, sample) {
  const n = /(\d+)\s*$/.exec(String(card || ''));
  if (!n) return undefined;
  const re = new RegExp(`(^|[^0-9])${n[1]}([^0-9]|$)`);
  const hit = (sample || []).find((s) => (s.issues || []).includes(Number(n[1])) || re.test(`${s.branch || ''} ${(s.worktree && s.worktree.name) || ''}`));
  return hit ? hit.session : undefined;
}

/** Takes the questions from a brief's reply into the inbox; each is addressed to the session that worked on its card. */
function receive(env, repoId, incoming, sample, now = Date.now()) {
  const s = load(env, repoId, now);
  for (const q of Array.isArray(incoming) ? incoming : []) {
    if (!q || typeof q.id !== 'string' || typeof q.words !== 'string' || !q.words.trim()) continue;
    if (s.questions.some((x) => x.id === q.id) || s.answered.includes(q.id)) continue;
    if (now - Date.parse(q.askedAt) >= KEPT_MS) continue;
    const session = workedOn(q.card, sample);
    s.questions.push({ id: q.id.slice(0, 40), card: String(q.card || '').slice(0, 120), name: String(q.name || q.card || 'a card').slice(0, 120), words: q.words.trim().slice(0, 300), askedAt: q.askedAt, ...(session ? { session } : {}) });
  }
  s.questions = s.questions.slice(-INBOX_MAX);
  save(env, repoId, s);
  return s;
}

const say = (q, repo, script) => `The builder asked about "${q.name}": "${q.words}" Answer in one sentence of at most ${ANSWER_MAX} characters: node ${script} --repo ${repo} --answer ${q.id} --say "..."`;

/** The questions this session should hear: addressed to it, or addressed to none (their session is gone) and not yet handed on. */
function forSession(env, repoId, session, { all = false } = {}) {
  const s = load(env, repoId);
  const mine = s.questions.filter((q) => (q.session ? q.session === session : !q.handed || all));
  return { questions: mine, state: s };
}

/** The one line a session start prints: the first question, and how many more wait. Marks the unaddressed ones handed. */
function lineFor(env, repoId, session, repo, script) {
  const { questions, state } = forSession(env, repoId, session);
  const fresh = questions.filter((q) => !q.seen || q.seen !== session);
  if (!fresh.length) return '';
  for (const q of fresh) { q.seen = session; if (!q.session) q.handed = true; }
  save(env, repoId, state);
  const more = fresh.length - 1;
  return say(fresh[0], repo, script) + (more ? ` ${more} more wait: node ${script} --repo ${repo} --questions` : '');
}

/** Every question waiting for this session, one line each, for the agent that asks. */
function listFor(env, repoId, session, repo, script) {
  return forSession(env, repoId, session, { all: true }).questions.map((q) => say(q, repo, script));
}

/** The agent's answer: kept for the next brief, and the question leaves the inbox. Returns false for an id nothing waits on. */
function answer(env, repoId, id, text) {
  const line = String(text || '').trim().replace(/\s+/g, ' ');
  if (!line) return false;
  const s = load(env, repoId);
  const q = s.questions.find((x) => x.id === id);
  if (!q) return false;
  s.questions = s.questions.filter((x) => x.id !== id);
  s.answered.push(id);
  save(env, repoId, s);
  const out = readJson(outboxFile(env, repoId), { answers: [] });
  out.answers = (Array.isArray(out.answers) ? out.answers : []).filter((a) => a.id !== id).concat({ id, say: line.slice(0, 300) }).slice(-INBOX_MAX);
  writeJson(outboxFile(env, repoId), out);
  return true;
}

/** The answers waiting to go with the next brief. */
function pendingAnswers(env, repoId) {
  const out = readJson(outboxFile(env, repoId), { answers: [] });
  return Array.isArray(out.answers) ? out.answers.filter((a) => a && a.id && a.say) : [];
}

/** The brief carrying them was received: they are not sent again. */
function clearAnswers(env, repoId, sent) {
  const ids = new Set(sent.map((a) => a.id));
  const left = pendingAnswers(env, repoId).filter((a) => !ids.has(a.id));
  writeJson(outboxFile(env, repoId), { answers: left });
}

module.exports = { receive, lineFor, listFor, answer, pendingAnswers, clearAnswers, workedOn, load, KEPT_MS };

'use strict';
// The pure layer of the owner console: read the project's console config and
// environment, and derive everything the page shows. Nothing here touches the
// network, and nothing here returns a setting's value, only whether it is set.

const fs = require('fs');
const path = require('path');

const CONFIG_PATH = path.join('console', 'services.json');

// The default questions an owner console answers, used when the project's
// config does not declare its own under faq.required. A project with
// different flows lists the ids it must answer there, and that list replaces
// this one. Either way the check fails when a required question is missing,
// so a project cannot quietly drop the question it has no answer to; the
// answer may say "not built yet".
const DEFAULT_REQUIRED_FAQ = {
  how: [
    ['merge-queue', 'run the merge queue on a fresh machine'],
    ['stage-upload', 'stage and upload'],
    ['importer', 'run the importer'],
    ['service-key', 'add a service key'],
    ['signing-key', 'renew a signing key'],
    ['backup', 'back up'],
    ['old-files', 'delete old files'],
    ['claim', 'confirm a claim'],
    ['report', 'answer a report'],
  ],
  when: [
    ['machine-form', 'a form is sent by a machine'],
    ['crawler-images', 'a crawler asks for images'],
    ['payment-fails', 'a payment fails'],
    ['storage-near-plan', 'storage nears the plan'],
    ['runners-offline', 'the runners are offline'],
    ['main-red', 'main goes red'],
    ['removal', 'a holder asks for removal'],
  ],
};

function loadConfig(root) {
  const file = path.join(root, CONFIG_PATH);
  if (!fs.existsSync(file)) {
    const err = new Error(`There is no console configuration yet. Copy the sample from the plugin's templates/console/services.json to ${CONFIG_PATH} in this project and describe the systems it talks to.`);
    err.code = 'NO_CONSOLE_CONFIG';
    throw err;
  }
  let text;
  try {
    text = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (e) {
    throw new Error(`The console configuration at ${CONFIG_PATH} is not valid JSON: ${e.message}`);
  }
  return normalize(text);
}

// Accept a setting written as a bare name or as {name, label}. A person only
// ever sees the label, so a bare name gets a plain-words label made from it.
function normalizeSetting(s) {
  if (typeof s === 'string') return { name: s, label: s.toLowerCase().replace(/_/g, ' ') };
  return { name: s.name, label: s.label || s.name.toLowerCase().replace(/_/g, ' ') };
}

function normalize(config) {
  const out = Object.assign({ project: 'This project', todo: [], systems: [], app: [], faq: {}, numbers: null }, config);
  out.systems = out.systems.map((sys) => ({
    id: sys.id,
    name: sys.name,
    vendor: sys.vendor || '',
    does: sys.does || '',
    settings: (sys.settings || []).map(normalizeSetting),
    optional: (sys.optional || []).map(normalizeSetting),
    parts: (sys.parts || []).map((p) => ({
      name: p.name,
      does: p.does || '',
      settings: (p.settings || []).map(normalizeSetting),
    })),
    links: sys.links || [],
    flows: sys.flows || [],
  }));
  out.todo = out.todo.map((t) => ({
    id: t.id,
    title: t.title,
    how: t.how || '',
    link: t.link || '',
    done_when: t.done_when || {},
  }));
  out.faq = { how: out.faq.how || [], when: out.faq.when || [], required: out.faq.required || null };
  return out;
}

// The questions this project must answer: its own list when it declares
// one, the default list otherwise. Each entry is [id, text]; a declared id
// takes its text from the matching FAQ entry when there is one.
function requiredFaq(config) {
  const declared = config.faq && config.faq.required;
  if (!declared) return DEFAULT_REQUIRED_FAQ;
  const out = { how: [], when: [] };
  for (const group of ['how', 'when']) {
    const byId = new Map((config.faq[group] || []).map((e) => [e.id, e.q]));
    for (const id of declared[group] || []) out[group].push([id, byId.get(id) || id]);
  }
  return out;
}

// Parse KEY=VALUE lines. Only the keys with a non-empty value count as set.
function parseEnvText(text) {
  const keys = new Set();
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const m = line.match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
    if (!m) continue;
    let value = m[2].trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    if (value !== '') keys.add(m[1]);
  }
  return keys;
}

// Keys named in the example env file, whether or not they have a value.
function parseEnvExampleKeys(text) {
  const keys = [];
  for (const raw of text.split(/\r?\n/)) {
    const m = raw.trim().match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=/);
    if (m) keys.push(m[1]);
  }
  return keys;
}

// Build an "is this setting present" function from the process environment
// and the project's .env file. Values never leave this function.
function presence(root, env) {
  const set = new Set();
  const envFile = path.join(root, '.env');
  if (fs.existsSync(envFile)) {
    for (const k of parseEnvText(fs.readFileSync(envFile, 'utf8'))) set.add(k);
  }
  for (const [k, v] of Object.entries(env || {})) {
    if (v !== undefined && v !== null && String(v).trim() !== '') set.add(k);
  }
  return (name) => set.has(name);
}

function isTruthyFlag(isPresent, env, name) {
  if (!isPresent(name)) return false;
  const v = env && env[name] !== undefined ? String(env[name]).trim().toLowerCase() : '';
  return !(v === '0' || v === 'false' || v === 'no' || v === 'off');
}

// ready: every required setting is set. to do: none is. partly: in between,
// or everything required is set but an optional one is not.
function systemState(system, isPresent) {
  const required = system.settings.concat(...system.parts.map((p) => p.settings));
  const optional = system.optional;
  const missingRequired = required.filter((s) => !isPresent(s.name));
  const missingOptional = optional.filter((s) => !isPresent(s.name));
  let state;
  if (required.length === 0) state = 'ready';
  else if (missingRequired.length === required.length) state = 'to do';
  else if (missingRequired.length > 0) state = 'partly';
  else if (missingOptional.length > 0) state = 'partly';
  else state = 'ready';
  return {
    state,
    missing: missingRequired.map((s) => s.label),
    missingOptional: missingOptional.map((s) => s.label),
  };
}

function missingNote(result) {
  const parts = [];
  if (result.missing.length) parts.push(`Still needed: ${joinPlain(result.missing)}.`);
  if (result.missingOptional.length) parts.push(`Optional and not set: ${joinPlain(result.missingOptional)}.`);
  if (!parts.length) return 'Everything this system needs is set.';
  return parts.join(' ');
}

function joinPlain(items) {
  if (items.length <= 1) return items.join('');
  return items.slice(0, -1).join(', ') + ' and ' + items[items.length - 1];
}

function deriveSystems(config, isPresent) {
  return config.systems.map((sys) => {
    const result = systemState(sys, isPresent);
    return Object.assign({}, sys, result, {
      note: missingNote(result),
      parts: sys.parts.map((p) => {
        const r = systemState({ settings: p.settings, optional: [], parts: [] }, isPresent);
        return Object.assign({}, p, r, { note: missingNote(r) });
      }),
    });
  });
}

// An item clears when its flag is set, when all its settings are set, or
// when the system it names is ready.
function deriveTodo(config, isPresent, env, systems) {
  const byId = new Map((systems || deriveSystems(config, isPresent)).map((s) => [s.id, s]));
  return config.todo.map((t) => {
    const w = t.done_when;
    let done = false;
    if (w.flag) done = isTruthyFlag(isPresent, env, w.flag);
    else if (w.settings) done = w.settings.every((n) => isPresent(typeof n === 'string' ? n : n.name));
    else if (w.system) done = byId.has(w.system) && byId.get(w.system).state === 'ready';
    return Object.assign({}, t, { done });
  });
}

// Every setting the config knows about, by name.
function knownSettingNames(config) {
  const names = new Set();
  for (const sys of config.systems) {
    for (const s of sys.settings) names.add(s.name);
    for (const s of sys.optional) names.add(s.name);
    for (const p of sys.parts) for (const s of p.settings) names.add(s.name);
  }
  for (const t of config.todo) {
    if (t.done_when.flag) names.add(t.done_when.flag);
    for (const n of t.done_when.settings || []) names.add(typeof n === 'string' ? n : n.name);
  }
  return names;
}

// Keys in the example env file that no card, part or to-do item claims.
function envExampleGaps(config, exampleText) {
  const known = knownSettingNames(config);
  return parseEnvExampleKeys(exampleText).filter((k) => !known.has(k));
}

// Required FAQ ids that the config does not answer.
function faqGaps(config) {
  const gaps = [];
  const required = requiredFaq(config);
  for (const group of ['how', 'when']) {
    const ids = new Set(config.faq[group].map((e) => e.id));
    for (const [id, text] of required[group]) if (!ids.has(id)) gaps.push({ group, id, text });
  }
  return gaps;
}

// Every link in the config: to a URL, to a section on the page, or to a
// file in the project. Returns the ones that do not resolve.
function linkGaps(config, root, fileExists) {
  const exists = fileExists || ((p) => fs.existsSync(path.join(root, p)));
  const ids = new Set(['todo', 'services', 'faq', 'numbers'].concat(config.systems.map((s) => s.id)));
  const gaps = [];
  const check = (where, href) => {
    if (!href) return;
    if (/^https?:\/\//.test(href)) {
      try { new URL(href); } catch (e) { gaps.push({ where, href, why: 'not a valid address' }); }
      return;
    }
    if (href.startsWith('#')) {
      if (!ids.has(href.slice(1))) gaps.push({ where, href, why: 'no such section on the page' });
      return;
    }
    if (!exists(href)) gaps.push({ where, href, why: 'no such file in the project' });
  };
  for (const sys of config.systems) for (const l of sys.links) check(`system ${sys.id}`, l.url);
  for (const t of config.todo) check(`to-do ${t.id}`, t.link);
  for (const group of ['how', 'when']) {
    for (const e of config.faq[group]) check(`faq ${e.id}`, e.link);
  }
  return gaps;
}

// Everything the page needs, in one object the renderer turns into HTML.
function buildView(config, options) {
  const opts = options || {};
  const isPresent = opts.isPresent || (() => false);
  const env = opts.env || {};
  const systems = deriveSystems(config, isPresent);
  const todo = deriveTodo(config, isPresent, env, systems);
  return {
    project: config.project,
    todo,
    systems,
    app: config.app,
    faq: config.faq,
    numbers: config.numbers,
    live: opts.live || null,
    mount: opts.mount || 'local',
  };
}

module.exports = {
  CONFIG_PATH,
  DEFAULT_REQUIRED_FAQ,
  requiredFaq,
  loadConfig,
  normalize,
  parseEnvText,
  parseEnvExampleKeys,
  presence,
  systemState,
  deriveSystems,
  deriveTodo,
  knownSettingNames,
  envExampleGaps,
  faqGaps,
  linkGaps,
  buildView,
};

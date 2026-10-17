'use strict';
// Tests for the owner console's pure parts. Run with: node --test console/test
// The sample config under templates/ is the fixture, so the sample stays
// valid as the code changes.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const config = require('../config');
const render = require('../render');
const { createConsole } = require('../index');

const root = path.join(__dirname, '..', '..', 'templates');
const cfg = config.loadConfig(root);
const exampleText = fs.readFileSync(path.join(root, '.env.example'), 'utf8');

const presentFrom = (names) => (n) => names.includes(n);

test('parseEnvText counts only keys with a value', () => {
  const keys = config.parseEnvText('A=1\nB=\n# C=3\nexport D="x"\nE=\'\'\n');
  assert.deepEqual([...keys].sort(), ['A', 'D']);
});

test('parseEnvExampleKeys lists every key, with or without a value', () => {
  assert.deepEqual(config.parseEnvExampleKeys('A=\nB=2\n# note\n'), ['A', 'B']);
});

test('a system with every setting is ready', () => {
  const r = config.systemState(cfg.systems.find((s) => s.id === 'database'), presentFrom(['DATABASE_URL']));
  assert.equal(r.state, 'ready');
  assert.deepEqual(r.missing, []);
});

test('a system with no setting is to do, and the note names the label not the variable', () => {
  const db = cfg.systems.find((s) => s.id === 'database');
  const r = config.systemState(db, presentFrom([]));
  assert.equal(r.state, 'to do');
  const [view] = config.deriveSystems({ systems: [db], todo: [] }, presentFrom([]));
  assert.match(view.note, /the database address/);
  assert.doesNotMatch(view.note, /DATABASE_URL/);
});

test('some settings present is partly, and a missing optional is partly', () => {
  const storage = cfg.systems.find((s) => s.id === 'storage');
  assert.equal(config.systemState(storage, presentFrom(['STORAGE_BUCKET'])).state, 'partly');
  const email = cfg.systems.find((s) => s.id === 'email');
  assert.equal(config.systemState(email, presentFrom(['EMAIL_API_KEY'])).state, 'partly');
  assert.equal(config.systemState(email, presentFrom(['EMAIL_API_KEY', 'EMAIL_FROM'])).state, 'ready');
});

test('parts are judged one by one and the card follows all of them', () => {
  const media = cfg.systems.find((s) => s.id === 'media');
  const [v] = config.deriveSystems({ systems: [media], todo: [] }, presentFrom(['MEDIA_CACHE_ZONE']));
  assert.equal(v.state, 'partly');
  assert.equal(v.parts[0].state, 'ready');
  assert.equal(v.parts[1].state, 'to do');
});

test('a to-do item clears from a flag, from settings, or from a ready system', () => {
  const env = { DONE_RUNNERS: '1', DONE_BACKUP: 'false', SESSION_SIGNING_KEY: 'x', DATABASE_URL: 'y' };
  const isPresent = (n) => env[n] !== undefined && env[n] !== '';
  const todo = Object.fromEntries(config.deriveTodo(cfg, isPresent, env).map((t) => [t.id, t.done]));
  assert.equal(todo.runners, true, 'flag set to 1 clears');
  assert.equal(todo.backup, false, 'flag set to false does not clear');
  assert.equal(todo['signing-key'], true, 'settings present clears');
  assert.equal(todo.database, true, 'ready system clears');
  assert.equal(todo.storage, false, 'to-do system stays');
});

test('every name in the example env file has a card, part or to-do item', () => {
  assert.deepEqual(config.envExampleGaps(cfg, exampleText), []);
});

test('a name in the example env file with no card is reported', () => {
  assert.deepEqual(config.envExampleGaps(cfg, exampleText + 'MYSTERY_KEY=\n'), ['MYSTERY_KEY']);
});

test('every required question is present in the sample FAQ', () => {
  assert.deepEqual(config.faqGaps(cfg), []);
});

test('a missing required question is reported', () => {
  const trimmed = config.normalize(JSON.parse(JSON.stringify(cfg)));
  trimmed.faq.how = trimmed.faq.how.filter((e) => e.id !== 'backup');
  const gaps = config.faqGaps(trimmed);
  assert.equal(gaps.length, 1);
  assert.equal(gaps[0].id, 'backup');
});

test('a project declares its own required questions and the default list no longer applies', () => {
  const own = config.normalize({
    project: 'Stations',
    faq: {
      required: { how: ['restart-a-station'], when: ['a-station-goes-quiet'] },
      how: [{ id: 'restart-a-station', q: 'Restart a station?', a: 'Press the button.' }],
      when: [],
    },
  });
  const gaps = config.faqGaps(own);
  assert.deepEqual(gaps.map((g) => g.id), ['a-station-goes-quiet']);
  assert.equal(gaps[0].text, 'a-station-goes-quiet');
});

test('every link in the sample config resolves', () => {
  assert.deepEqual(config.linkGaps(cfg, root), []);
});

test('a link to a missing file or section is reported', () => {
  const broken = config.normalize(JSON.parse(JSON.stringify(cfg)));
  broken.systems[0].links.push({ label: 'x', url: 'no/such/file.md' });
  broken.faq.when[0].link = '#nowhere';
  const gaps = config.linkGaps(broken, root);
  assert.equal(gaps.length, 2);
});

test('the page has the four parts in order and no variable names', () => {
  const view = config.buildView(cfg, { isPresent: presentFrom(['DATABASE_URL']), env: {}, mount: 'local' });
  const html = render.renderPage(view);
  const order = ['id="todo"', 'id="services"', 'id="faq"', 'id="numbers"'].map((s) => html.indexOf(s));
  assert.ok(order.every((i) => i >= 0), 'all four sections present');
  assert.deepEqual(order, [...order].sort((a, b) => a - b), 'in order');
  for (const name of config.knownSettingNames(cfg)) {
    assert.ok(!html.includes(name), `the page must not name ${name}`);
  }
  assert.match(html, /This local copy leaves them out/);
  assert.match(html, /Not built yet\./);
});

test('the map draws the browser and the app parts dashed and one node per system', () => {
  const view = config.buildView(cfg, { isPresent: presentFrom([]), env: {} });
  const svg = render.renderMap(view);
  assert.equal((svg.match(/class="node own"/g) || []).length, 1 + cfg.app.length);
  assert.equal((svg.match(/class="node (ready|partly|todo)"/g) || []).length, cfg.systems.length);
  assert.match(svg, /reads and writes/);
});

test('the online mount shows live numbers from the project function', async () => {
  const c = createConsole({ root, env: {}, numbers: async () => ({ accounts: 12, items: 340, storage_used: '2.1 GB' }) });
  const html = await c.html();
  assert.match(html, /<b>12<\/b>Accounts/);
  assert.match(html, /2\.1 GB/);
});

test('the online mount says so when the numbers cannot be read', async () => {
  const c = createConsole({ root, env: {}, numbers: async () => { throw new Error('down'); } });
  const html = await c.html();
  assert.match(html, /could not be read just now/);
});

test('a project with no config gets a plain sentence, not a path error', () => {
  assert.throws(() => config.loadConfig(path.join(__dirname)), /no console configuration yet/);
});

test('the local mount leaves the numbers out and says so', async () => {
  const c = createConsole({ root, env: {} });
  const html = await c.html();
  assert.match(html, /This local copy leaves them out/);
  assert.doesNotMatch(html, /<b>12<\/b>/);
});

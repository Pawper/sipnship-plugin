'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const cp = require('child_process');
const { designUse, literalsOf } = require('../design-use');

// Maya's rooftop-garden app: two screens, a part and a few tokens.
function garden() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-design-'));
  const put = (f, text) => { fs.mkdirSync(path.dirname(path.join(root, f)), { recursive: true }); fs.writeFileSync(path.join(root, f), text); };
  put('design/tokens.json', JSON.stringify({
    ground: [{ key: 'soil', hex: '#3B2A1E' }],
    accents: [{ key: 'terracotta', stops: ['#C8643C', '#B85A34'] }],
    type: { roles: [{ key: 'label', size: 12 }] },
    spacing: { bedGap: { $value: 16 } },
    blocks: { bed: { width: { $value: 120 } } },
    parts: { bedCard: { gap: { $value: '{spacing.bedGap}' } } },
  }));
  put('scripts/ci/design-ui.txt', 'src/**/*.ts\n');
  put('scripts/ci/mocks.txt', '# screens\ntoday src/today.ts design/mocks/Today.html\n');
  put('src/today.ts', ['// soil is a comment word', 'const a = tokens.terracotta;', 'const b = "type-label";', 'const c = bedCard();', 'const gap = 16px; const x = "#C9653D";', 'const w = bed.width;'].join('\n'));
  put('src/harvest.ts', 'const a = Color.soil; const pad = 24px; const e = 1px; const z = 0px;\n');
  cp.execFileSync('git', ['init', '-q'], { cwd: root });
  cp.execFileSync('git', ['add', '-A'], { cwd: root });
  return root;
}

test('each token says the screens that use it and the parts that point at it', () => {
  const d = designUse({ root: garden(), now: new Date('2026-11-02T09:15:00Z') });
  assert.strictEqual(d.at, '2026-11-02T09:15:00.000Z');
  assert.deepStrictEqual(d.tokens.terracotta, { parts: [], screens: ['today'] });
  assert.deepStrictEqual(d.tokens.soil, { parts: [], screens: ['harvest'] });
  assert.deepStrictEqual(d.tokens.label, { parts: [], screens: ['today'] });
  assert.deepStrictEqual(d.tokens.bedGap, { parts: ['bedCard'], screens: [] });
  assert.deepStrictEqual(d.tokens['bed.width'], { parts: [], screens: ['today'] });
  assert.deepStrictEqual(d.tokens['parts.bedCard'], { parts: [], screens: ['today'] });
});

test('the literals are what the design check finds, with the nearest token', () => {
  const d = designUse({ root: garden() });
  const find = (v, s) => d.literals.find((l) => l.value === v && l.screen === s);
  assert.deepStrictEqual(find('#C9653D', 'today'), { value: '#C9653D', screen: 'today', near: 'terracotta' });
  assert.deepStrictEqual(find('16px', 'today'), { value: '16px', screen: 'today', near: 'bedGap' });
  assert.deepStrictEqual(find('24px', 'harvest'), { value: '24px', screen: 'harvest' });
  assert.strictEqual(d.literals.some((l) => l.value === '1px' || l.value === '0px'), false);
});

test('a comment line holds no literal', () => {
  assert.deepStrictEqual(literalsOf('// #FF0000 and 12px\n/* 9dp */\n * 0xFF112233', undefined), []);
});

test('a project with no tokens file sends nothing', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sns-design-'));
  assert.strictEqual(designUse({ root }), undefined);
});

test('only names and values are sent, never code', () => {
  const text = JSON.stringify(designUse({ root: garden() }));
  assert.strictEqual(text.includes('tokens.terracotta'), false);
  assert.strictEqual(text.includes('Color.soil'), false);
});

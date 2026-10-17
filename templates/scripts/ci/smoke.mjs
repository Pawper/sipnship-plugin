#!/usr/bin/env node
// Load each page of a deployed site in a real browser and fail on any
// console error or uncaught exception. Tests and the type-check passed on
// a client bug that made every screen throw in production; only loading
// the pages would have shown it.
//
// Usage: node scripts/ci/smoke.mjs BASE_URL [PATH...]   (default path: /)
// Needs playwright with chromium installed; the smoke workflow does that.

const [base, ...paths] = process.argv.slice(2);
if (!base) {
  process.stderr.write('Give the base URL of the deployed site.\n');
  process.exit(2);
}

let chromium;
try {
  ({ chromium } = await import('playwright'));
} catch {
  process.stderr.write('playwright is not installed; the smoke workflow installs it.\n');
  process.exit(2);
}

const browser = await chromium.launch();
const problems = [];
for (const path of paths.length ? paths : ['/']) {
  const page = await browser.newPage();
  page.on('console', (m) => { if (m.type() === 'error') problems.push(`${path}: console error: ${m.text()}`); });
  page.on('pageerror', (e) => problems.push(`${path}: uncaught: ${e.message}`));
  const res = await page.goto(new URL(path, base).toString(), { waitUntil: 'networkidle', timeout: 45000 }).catch((e) => {
    problems.push(`${path}: did not load: ${e.message}`);
    return null;
  });
  if (res && res.status() >= 400) problems.push(`${path}: HTTP ${res.status()}`);
  await page.close();
}
await browser.close();

if (problems.length) {
  process.stderr.write(`The deployed site has ${problems.length} problem(s):\n${problems.map((p) => `  ${p}`).join('\n')}\n`);
  process.exit(1);
}
process.stdout.write(`Loaded ${paths.length || 1} page(s) with no console errors.\n`);

#!/usr/bin/env node
// Run one test file through the test runner's own API, so the queue can
// prove a merged PR without a sweep. A hook refuses the bare sweep command
// on purpose; this is the targeted run it asks for.
//
// The file is run from its own package: the nearest folder above it with a
// package.json, which is where its node_modules and vitest config live. A
// project whose app sits in web/ with its own dependencies therefore works
// from the repository root, and the runner is found next to the test.
//
// Usage: node scripts/ci/run-test-file.mjs path/to/one.test.ts
// Exit 0 when the file passes, 1 when it fails, 2 when it cannot run (and
// say why on stderr: a runner that cannot start is not a red test).

import { existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const file = process.argv[2];
if (!file) {
  process.stderr.write('Give one test file to run.\n');
  process.exit(2);
}

const absolute = path.resolve(file);
if (!existsSync(absolute)) {
  process.stderr.write(`No such test file: ${file}\n`);
  process.exit(2);
}

// packageRoot(FILE): the nearest folder above FILE that holds a package.json,
// or the current folder when none does.
export function packageRoot(fromFile, cwd = process.cwd()) {
  let dir = path.dirname(fromFile);
  for (;;) {
    if (existsSync(path.join(dir, 'package.json'))) return dir;
    const up = path.dirname(dir);
    if (up === dir) return cwd;
    dir = up;
  }
}

const root = packageRoot(absolute);
process.chdir(root);
const relative = path.relative(root, absolute).split(path.sep).join('/');

let startVitest;
try {
  const resolve = createRequire(path.join(root, 'package.json'));
  ({ startVitest } = await import(pathToFileURL(resolve.resolve('vitest/node')).href));
} catch (e) {
  process.stderr.write(`The test runner could not be loaded from ${root} (${e?.message ?? e}); install it there or set QUEUE_TEST_COMMAND to the project's one-file test command.\n`);
  process.exit(2);
}

const ctx = await startVitest('test', [relative], { run: true, watch: false, reporters: ['dot'] });
if (!ctx) {
  process.stderr.write(`The runner did not start for ${relative} in ${root}.\n`);
  process.exit(2);
}
await ctx.close();
const failed = typeof ctx.state?.getCountOfFailedTests === 'function'
  ? ctx.state.getCountOfFailedTests()
  : (process.exitCode || 0);
process.exit(failed > 0 ? 1 : 0);

'use strict';
// The checks before an agent command, in one process (specs/027-hooks-in-node).
//
//   node run.js pre-bash [--only NAME]    the nine checks before a Bash call
//
// Reads the event on standard input once, runs each check, and prints the
// words of every refusal to standard error; exits 2 when any check refused,
// else 0, as the shell hooks do. --only runs one check by its hook's name
// (the proof feeds each case to the shell hook and to this, one hook at a time).
// This first block is plain syntax so a Node below the floor reaches it:
// there the program ends at once with no output, and the checks are skipped
// (CI still enforces every rule on the pull request).
var floor = 18;
try { floor = parseInt(String(require('../../package.json').engines.node).replace(/[^0-9]/g, ''), 10) || 18; } catch (e) { /* the default */ }
if (parseInt(process.versions.node, 10) < floor) process.exit(0);

const { jsonField, shellValue } = require('./text');
const { refusalLog, timingDir, timingStart, timingEnd, timingBound, timingTrim } = require('./logs');
const { BASH } = require('./checks');

function readInput() {
  const fs = require('fs');
  try { return fs.readFileSync(0, 'utf8'); } catch (e) { return ''; }
}

function main(argv) {
  const event = argv[0];
  const oi = argv.indexOf('--only');
  const only = oi >= 0 ? argv[oi + 1] : '';
  if (event !== 'pre-bash') return 0;
  const input = readInput();
  const cmd = shellValue(jsonField(input, 'command'));
  const session = shellValue(jsonField(input, 'session_id'));
  const root = process.env.CLAUDE_PROJECT_DIR || shellValue(jsonField(input, 'cwd'));
  const dir = timingDir();
  const refusals = [];
  for (const [name, limit, check] of BASH) {
    if (only && only !== name) continue;
    const ctx = { input, cmd, session, root, name, onBound: (s) => timingBound(dir, name, s) };
    const t0 = Date.now();
    timingStart(dir, name, limit);
    let words = null;
    try { words = check(ctx); } catch (e) { words = null; }
    timingEnd(dir, name, limit, Date.now() - t0);
    if (words !== null) { refusals.push(words); refusalLog(name, session); }
  }
  timingTrim(dir);
  if (refusals.length === 0) return 0;
  process.stderr.write(refusals.join('\n') + '\n');
  return 2;
}

process.exitCode = main(process.argv.slice(2));

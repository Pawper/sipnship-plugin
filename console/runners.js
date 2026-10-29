'use strict';
// The Runners card: two facts the machine knows and GitHub does not. How
// long jobs waited for a runner this week, from the queue's own log
// (.scratch/queue/waits.tsv), and the machine line the runner watch keeps
// (~/.sipnship/runner-watch/machine.tsv). Local files only; nothing is sent.

const fs = require('fs');
const os = require('os');
const path = require('path');

const WEEK = 7 * 86400;

// The same sentence the session brief prints, or '' when no job waited.
function waitsLine(text, nowSec) {
  let n = 0; let max = 0; let tot = 0; let busy = 0; let some = false;
  for (const row of String(text || '').split(/\r?\n/)) {
    const f = row.split('\t');
    if (f.length < 6 || Number(f[0]) < nowSec - WEEK) continue;
    n++;
    max = Math.max(max, Number(f[5]) || 0);
    tot = Math.max(tot, Number(f[4]) || 0);
    busy = Math.max(busy, Number(f[3]) || 0);
    if ((Number(f[3]) || 0) < (Number(f[4]) || 0)) some = true;
  }
  if (!n) return '';
  const times = n === 1 ? 'once' : `${n} times`;
  const mins = max === 1 ? '1 minute' : `${max} minutes`;
  let how = '';
  if (tot && !some) how = tot === 1 ? ', when the one runner was busy' : `, when all ${tot} were busy`;
  else if (tot) how = `, with up to ${busy} of ${tot} busy`;
  return `Jobs waited for a runner ${times} this week, ${mins} at most${how}.`;
}

// The machine file's line and whether its runners exceed one per two cores.
function machineFact(text) {
  const f = String(text || '').split(/\r?\n/)[0].split('\t');
  if (f.length < 5) return null;
  const cores = Number(f[1]) || 0; const here = Number(f[2]) || 0;
  return { line: f[4], over: cores > 0 && here > Math.floor(cores / 2) };
}

// A card in the console's own form, or null when there is nothing to say.
function runnersCard(waitsText, machineText, nowSec) {
  const waits = waitsLine(waitsText, nowSec);
  const machine = machineFact(machineText);
  if (!waits && !machine) return null;
  const line = machine ? `This machine: ${machine.line}.` : '';
  return {
    id: 'runners',
    name: 'Runners',
    state: machine && machine.over ? 'partly' : 'ready',
    vendor: '',
    does: waits || 'No job waited for a runner this week.',
    note: line,
    parts: [],
    links: [],
  };
}

function readText(file) {
  try { return fs.readFileSync(file, 'utf8'); } catch (e) { return ''; }
}

function readRunnersCard(root, home, nowSec) {
  const base = home ? path.join(home, '.sipnship') : (process.env.SIPNSHIP_HOME || path.join(os.homedir(), '.sipnship'));
  const dir = path.join(base, 'runner-watch');
  return runnersCard(
    readText(path.join(root, '.scratch', 'queue', 'waits.tsv')),
    readText(path.join(dir, 'machine.tsv')),
    nowSec,
  );
}

module.exports = { waitsLine, machineFact, runnersCard, readRunnersCard };

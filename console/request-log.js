'use strict';
// ~/.sipnship/requests.log (or $SIPNSHIP_HOME): one line per request this
// machine carried out or refused: when, kind, who asked, who approved,
// the outcome. Never a parameter's output, a command or a log's text. Kept
// until the person clears it.

const fs = require('fs');
const path = require('path');
const tokens = require('./tokens');

const file = (env = process.env) => path.join(tokens.home(env), 'requests.log');
const clean = (s) => String(s || '').replace(/[\t\r\n]+/g, ' ').slice(0, 80);

function append({ at = new Date().toISOString(), kind, askedBy, approvedBy, outcome }, env = process.env) {
  fs.mkdirSync(tokens.home(env), { recursive: true, mode: 0o700 });
  fs.appendFileSync(file(env), [at, kind, askedBy, approvedBy, outcome].map(clean).join('\t') + '\n');
}

// recent(n): the last n lines, newest first, as fields the console labels.
function recent(n = 20, env = process.env) {
  let text = '';
  try { text = fs.readFileSync(file(env), 'utf8'); } catch { return []; }
  return text.split('\n').filter(Boolean).slice(-n).reverse().map((l) => {
    const [at, kind, askedBy, approvedBy, outcome] = l.split('\t');
    return { at, kind, askedBy, approvedBy, outcome };
  });
}

module.exports = { file, append, recent };

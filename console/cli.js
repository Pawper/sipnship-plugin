#!/usr/bin/env node
'use strict';
// node "$CLAUDE_PLUGIN_ROOT/console/cli.js" console [--port 7777] [--root .] [--check]
//
// console        serve the owner console for the project in the current folder
// console --check  do not serve; fail when the config has gaps (used by CI and tests)
// console --no-delivery  leave out the Delivery section (no GitHub reads)
// queue-demo [--out FILE]  write the self-playing merge queue page, for a site
// permissions  a person, in a terminal, chooses the commands the agent may run
// connect --repo [OWNER/NAME] [--token T]  send the brief to the dashboard
// disconnect [--repo OWNER/NAME]  stop sending it

const path = require('path');
const fs = require('fs');
const { serve } = require('./index');
const config = require('./config');

function usage() {
  process.stdout.write(`Usage:
  sipnship console [--port N] [--root <project>]
  sipnship console --check [--root <project>]
  sipnship queue-demo [--out <file>]
  sipnship permissions [--root <project>]
  sipnship connect --repo [OWNER/NAME] [--token <token>]
  sipnship disconnect [--repo OWNER/NAME]

connect sends this repository's session brief to the SipNShip dashboard:
it shows a code to approve there, then keeps the repository's token in
~/.sipnship/tokens.json (or $SIPNSHIP_HOME), outside every repository.
--token installs one the dashboard's Rotate made. disconnect stops it.

Serves the owner console for the project at <project> (default: the current
folder) on localhost, on the port this project claimed on this machine the
first time it ran (kept in ~/.sipnship/console-ports.json; the first free
unclaimed number from 7777 up), or .claude/console.json's "port". A port
another project claims is never taken, even while its console is stopped.
When the port is in use, a console of this project there is reused. --check reads the config and the example env file and
fails when a setting has no card, a required question is missing, or a link
does not resolve. --no-delivery leaves out the Delivery section, which
reads the project's CI runs and pull requests from GitHub. queue-demo
writes one page that plays a scripted merge queue.
`);
}

function parseArgs(argv) {
  const out = { command: argv[0], port: 0, root: process.cwd(), check: false, delivery: true, out: null };
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--port') out.port = Number(argv[++i]);
    else if (a === '--root') out.root = path.resolve(argv[++i]);
    else if (a === '--check') out.check = true;
    else if (a === '--no-delivery') out.delivery = false;
    else if (a === '--out') out.out = argv[++i];
    else if (a === '--help' || a === '-h') out.command = 'help';
  }
  return out;
}

function check(root) {
  const cfg = config.loadConfig(root);
  const problems = [];
  const examplePath = path.join(root, '.env.example');
  if (fs.existsSync(examplePath)) {
    for (const k of config.envExampleGaps(cfg, fs.readFileSync(examplePath, 'utf8'))) {
      problems.push(`The example env file names ${k} but no card, part or to-do item claims it.`);
    }
  }
  for (const g of config.faqGaps(cfg)) problems.push(`The FAQ has no "${g.group === 'how' ? 'How do I' : 'What happens when'}" entry for: ${g.text} (id ${g.id}).`);
  for (const g of config.linkGaps(cfg, root)) problems.push(`In ${g.where}, the link ${g.href} does not resolve: ${g.why}.`);
  return problems;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.command === 'queue-demo') {
    const page = require('./queue-view').demoPage();
    if (args.out) { fs.writeFileSync(args.out, page); process.stdout.write(`Wrote ${args.out}\n`); } else process.stdout.write(page);
    return;
  }
  if (args.command === 'connect' || args.command === 'disconnect') {
    const rest = process.argv.slice(3);
    const value = (name) => { const i = rest.indexOf(name); return i >= 0 && rest[i + 1] && !rest[i + 1].startsWith('--') ? rest[i + 1] : undefined; };
    const c = require('./connect');
    process.exitCode = args.command === 'connect'
      ? await c.connect({ repo: value('--repo'), token: rest.includes('--token') ? (value('--token') ?? '') : undefined })
      : await c.disconnect({ repo: value('--repo') });
    return;
  }
  if (args.command === 'permissions') { process.exitCode = await require('./permissions').run(args.root); return; }
  if (args.command !== 'console') { usage(); process.exit(args.command === 'help' ? 0 : 2); }
  if (args.check) {
    const problems = check(args.root);
    if (problems.length) {
      process.stderr.write(problems.join('\n') + '\n');
      process.exit(1);
    }
    process.stdout.write('The console configuration is complete.\n');
    return;
  }
  config.loadConfig(args.root);
  const { url, reused, skipped } = await serve({ root: args.root, port: args.port, delivery: args.delivery });
  for (const s of skipped) process.stdout.write(s.claimed ? `Port ${s.port} belongs to ${s.root}; trying the next.\n` : `Port ${s.port} is in use${s.project ? ` by the ${s.project} console${s.root ? ` (${s.root})` : ''}` : ' by something else'}; trying the next.\n`);
  if (reused) { process.stdout.write(`This project's console is already running: ${url}\n`); return; }
  process.stdout.write(`Owner console for ${args.root}\n${url}\nPress Ctrl+C to stop.\n`);
}

main().catch((e) => {
  process.stderr.write(`${e.message}\n`);
  process.exit(1);
});

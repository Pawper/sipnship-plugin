#!/usr/bin/env node
'use strict';
// node "$CLAUDE_PLUGIN_ROOT/console/cli.js" console [--port 7777] [--root .] [--check]
//
// console        serve the owner console for the project in the current folder
// console --check  do not serve; fail when the config has gaps (used by CI and tests)
// console --no-delivery  leave out the Delivery section (no GitHub reads)
// queue-demo [--out FILE]  write the self-playing merge queue page, for a site

const path = require('path');
const fs = require('fs');
const { serve } = require('./index');
const config = require('./config');

function usage() {
  process.stdout.write(`Usage:
  sipnship console [--port 7777] [--root <project>]
  sipnship console --check [--root <project>]
  sipnship queue-demo [--out <file>]

Serves the owner console for the project at <project> (default: the current
folder) on localhost. --check reads the config and the example env file and
fails when a setting has no card, a required question is missing, or a link
does not resolve. --no-delivery leaves out the Delivery section, which
reads the project's CI runs and pull requests from GitHub. queue-demo
writes one page that plays a scripted merge queue.
`);
}

function parseArgs(argv) {
  const out = { command: argv[0], port: 7777, root: process.cwd(), check: false, delivery: true, out: null };
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
  const { url } = await serve({ root: args.root, port: args.port, delivery: args.delivery });
  process.stdout.write(`Owner console for ${args.root}\n${url}\nPress Ctrl+C to stop.\n`);
}

main().catch((e) => {
  process.stderr.write(`${e.message}\n`);
  process.exit(1);
});

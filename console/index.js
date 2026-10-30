'use strict';
// The owner console, two mounts from one source.
//
//   Local:  serve({ root }) starts a small server on localhost that reads
//           console/services.json and the environment of the project at root.
//   Online: createConsole({ root, numbers }).handler is a (req, res) handler
//           the project mounts on a route behind its own owner sign-in.
//
// Both build the same view and render the same page.

const http = require('http');
const fs = require('fs');
const path = require('path');
const config = require('./config');
const render = require('./render');
const delivery = require('./delivery');
const queueView = require('./queue-view');
const runners = require('./runners');

function createConsole(options) {
  const opts = options || {};
  const root = opts.root || process.cwd();
  const mount = opts.mount || (opts.numbers ? 'online' : 'local');

  async function view() {
    const cfg = config.loadConfig(root);
    const env = opts.env || process.env;
    const isPresent = config.presence(root, env);
    let live = null;
    if (mount === 'online' && typeof opts.numbers === 'function' && cfg.numbers) {
      try { live = await opts.numbers(); } catch (e) { live = null; }
    }
    const v = config.buildView(cfg, { isPresent, env, live, mount });
    // Which folder this is, under the name: several projects' consoles on
    // one machine once showed one project's page at another's address.
    if (mount === 'local') v.where = root;
    // The Runners card reads two local files on this machine only.
    if (mount === 'local') v.runners = runners.readRunnersCard(root, opts.home, Math.floor(Date.now() / 1000));
    // Delivery reads GitHub with the gh sign-in on this machine, so it is
    // on for the local mount and off online unless the project asks.
    if (opts.delivery !== false && (mount === 'local' || opts.delivery === true)) {
      try {
        const raw = await delivery.gather(root);
        v.delivery = delivery.summarize(raw, Date.now());
        v.queue = queueView.queueState(delivery.queueView(raw));
      } catch (e) { v.delivery = null; }
    }
    return v;
  }

  async function queueJson(req, res) {
    try {
      const raw = await delivery.gather(root, { queueOnly: true });
      res.statusCode = 200;
      res.setHeader('Content-Type', 'application/json; charset=utf-8');
      res.setHeader('Cache-Control', 'no-store');
      res.end(JSON.stringify(queueView.queueState(delivery.queueView(raw))));
    } catch (e) { res.statusCode = 500; res.end('{}'); }
  }

  async function html() {
    return render.renderPage(await view());
  }

  async function handler(req, res) {
    try {
      const page = await html();
      res.statusCode = 200;
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      res.setHeader('Cache-Control', 'no-store');
      res.end(page);
    } catch (e) {
      res.statusCode = 500;
      res.setHeader('Content-Type', 'text/plain; charset=utf-8');
      res.end(`The console could not build the page: ${e.message}\n`);
    }
  }

  return { view, html, handler, queueJson, root, mount };
}

// Console ports are claimed per machine and kept: a project keeps the port
// it first served on, and a newcomer takes the lowest number from 7777 up
// that no project has claimed, even when a claimed port is free at the
// moment. Every project once defaulted to 7777; one console stopped, its
// tab stayed open, another project's console took the port, and the tab
// showed the wrong project. The claims live in the user's folder, never in
// a repository, since ports belong to the machine:
// ~/.sipnship/console-ports.json, { "ports": { "<folder>": 7777 } }.
// .claude/console.json's "port" in a project overrides its claim.
const os = require('os');
const FIRST_PORT = 7777;

function claimsFile(home) {
  if (home) return path.join(home, '.sipnship', 'console-ports.json');
  return path.join(process.env.SIPNSHIP_HOME || path.join(os.homedir(), '.sipnship'), 'console-ports.json');
}

function folderKey(p) {
  const r = path.resolve(p).replace(/[\\/]+$/, '');
  return process.platform === 'win32' ? r.toLowerCase() : r;
}

function readClaims(home) {
  try { return JSON.parse(fs.readFileSync(claimsFile(home), 'utf8')).ports || {}; } catch (e) { return {}; }
}

function writeClaim(root, port, home) {
  const f = claimsFile(home);
  const ports = readClaims(home);
  ports[folderKey(root)] = port;
  try {
    fs.mkdirSync(path.dirname(f), { recursive: true });
    fs.writeFileSync(f, JSON.stringify({ ports }, null, 2) + '\n');
  } catch (e) { /* a console still serves without its claim saved */ }
}

// portFor(root, home): the port this project should serve on.
function portFor(root, home) {
  try {
    const cfg = JSON.parse(fs.readFileSync(path.join(root, '.claude', 'console.json'), 'utf8'));
    if (Number(cfg.port) > 0) return Number(cfg.port);
  } catch (e) { /* no project setting */ }
  const ports = readClaims(home);
  if (ports[folderKey(root)]) return ports[folderKey(root)];
  const taken = new Set(Object.values(ports).map(Number));
  let p = FIRST_PORT;
  while (taken.has(p)) p += 1;
  return p;
}

// claimedBy(port, root, home): another project's folder that claims PORT.
function claimedBy(port, root, home) {
  const ports = readClaims(home);
  const mine = folderKey(root);
  for (const [k, v] of Object.entries(ports)) if (Number(v) === port && k !== mine) return k;
  return '';
}

function sameFolder(a, b) {
  const norm = (p) => path.resolve(p).replace(/[\\/]+$/, '');
  return process.platform === 'win32' ? norm(a).toLowerCase() === norm(b).toLowerCase() : norm(a) === norm(b);
}

function fetchText(host, port, urlPath) {
  return new Promise((resolve) => {
    const req = http.get({ host, port, path: urlPath, timeout: 1500 }, (res) => {
      let body = '';
      res.on('data', (c) => { body += c; });
      res.on('end', () => resolve({ status: res.statusCode, body }));
    });
    req.on('timeout', () => { req.destroy(); resolve(null); });
    req.on('error', () => resolve(null));
  });
}

// whoIsOn(host, port): what a console on that port says it serves, or null.
// A console from before /whoami is named by its page title.
async function whoIsOn(host, port) {
  const w = await fetchText(host, port, '/whoami');
  if (w && w.status === 200) { try { return JSON.parse(w.body); } catch (e) { /* fall through */ } }
  const page = await fetchText(host, port, '/');
  const m = page && /<title>([^<]*) console<\/title>/.exec(page.body);
  return m ? { project: m[1], root: '' } : null;
}

function serve(options) {
  const opts = options || {};
  const root = opts.root || process.cwd();
  const home = opts.home;
  const first = Number(opts.port) || portFor(root, home);
  const host = '127.0.0.1';
  const console_ = createConsole({ root, env: opts.env, mount: 'local', delivery: opts.delivery });
  const server = http.createServer((req, res) => {
    if (req.url === '/whoami') {
      let project = '';
      try { project = config.loadConfig(root).project || ''; } catch (e) { project = ''; }
      res.statusCode = 200;
      res.setHeader('Content-Type', 'application/json; charset=utf-8');
      return res.end(JSON.stringify({ project, root: path.resolve(root) }));
    }
    if (req.url === '/queue.json') return console_.queueJson(req, res);
    if (req.url === '/' || req.url.startsWith('/?') || req.url === '/index.html') return console_.handler(req, res);
    res.statusCode = 404;
    res.setHeader('Content-Type', 'text/plain; charset=utf-8');
    res.end('Only the console page is served here.\n');
  });
  // A port already in use: this project's console there is reused; another
  // project's, or anything else, is named and the next port tried.
  const skipped = [];
  function attempt(port, left) {
    // A port another project claims is passed over even when it is free,
    // so a stopped console's open tab never shows a different project.
    const owner = claimedBy(port, root, home);
    if (owner && left > 0) {
      skipped.push({ port, project: '', root: owner, claimed: true });
      return attempt(port + 1, left - 1);
    }
    return new Promise((resolve, reject) => {
      const onError = async (e) => {
        if (e.code !== 'EADDRINUSE' || left <= 0) return reject(e);
        const who = await whoIsOn(host, port);
        if (who && who.root && sameFolder(who.root, root)) return resolve({ server: null, url: `http://${host}:${port}/`, reused: true, skipped });
        skipped.push({ port, project: (who && who.project) || '', root: (who && who.root) || '' });
        attempt(port + 1, left - 1).then(resolve, reject);
      };
      // Each attempt's listeners are its own and removed when it ends: a
      // listen callback left from a failed port fired on the next success
      // and reported the wrong address.
      const onListening = () => { server.removeListener('error', onErrorOnce); writeClaim(root, port, home); resolve({ server, url: `http://${host}:${port}/`, reused: false, skipped }); };
      const onErrorOnce = (e) => { server.removeListener('listening', onListening); onError(e); };
      server.once('error', onErrorOnce);
      server.once('listening', onListening);
      server.listen(port, host);
    });
  }
  return attempt(first, 20);
}

module.exports = { createConsole, serve, portFor, writeClaim, readClaims };

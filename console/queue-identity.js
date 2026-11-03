'use strict';
// sipnship queue-identity [--repo OWNER/NAME]
//
// Gives a repository's merge queue its own GitHub App, through GitHub's App
// manifest flow, in two clicks: one on a page this command serves on
// localhost (it sends GitHub the description of the App), one on GitHub's
// own page (Create GitHub App). GitHub then returns to localhost with a
// one-time code; the code is traded for the App's id and key; the id and the
// key are set as the repository secrets QUEUE_APP_ID and QUEUE_APP_KEY with
// the builder's own gh, and the page for installing the App opens. The key
// goes from GitHub's answer straight into gh's standard input: it is not
// written to a file, printed, or logged, and this process forgets it.

const http = require('http');
const crypto = require('crypto');
const { execFileSync, spawn } = require('child_process');
const { remoteRepo } = require('./connect');

const API = 'https://api.github.com';

/** The App's description. Names are unique across GitHub, so the repository is in it. */
function manifest(fullName, redirectUrl) {
  const [, name] = fullName.split('/');
  return {
    name: `${name} queue`.slice(0, 34),
    url: 'https://sipnship.dev',
    redirect_url: redirectUrl,
    public: false,
    default_permissions: {
      contents: 'write',
      pull_requests: 'write',
      issues: 'write',
      actions: 'write',
      workflows: 'write',
      checks: 'read',
      statuses: 'read',
      administration: 'write',
    },
    default_events: [],
  };
}

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function page(title, body) {
  return `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)}</title><body style="font:16px/1.5 system-ui,sans-serif;max-width:32rem;margin:3rem auto;padding:0 16px">${body}</body>`;
}

/** The page that sends GitHub the manifest: a form posted straight to GitHub, so nothing passes through SipNShip. */
function startPage(fullName, manifestJson, state, org) {
  const owner = fullName.split('/')[0];
  return page('Make the queue its own App', `<h1>Make the queue its own App</h1>
<p>This gives ${esc(fullName)}'s merge queue an identity of its own, so no personal token has to be pasted into the repository.</p>
<form id="f" method="post" action="${org ? `https://github.com/organizations/${encodeURIComponent(org)}/settings/apps/new` : "https://github.com/settings/apps/new"}?state=${encodeURIComponent(state)}">
<input type="hidden" name="manifest" value="${esc(manifestJson)}">
<button type="submit" style="font:inherit;padding:.6rem 1.2rem">Describe the App to GitHub</button>
</form>
<p style="font-size:14px">The App will belong to ${org ? `the organization ${esc(org)}` : 'your own account'}.${org ? '' : ` If ${esc(owner)} is an organization that should own it, run the command again with --org ${esc(owner)}.`}</p>`);
}

const defaultOpen = (url) => {
  const [cmd, args] = process.platform === 'win32' ? ['cmd', ['/c', 'start', '', url]] : process.platform === 'darwin' ? ['open', [url]] : ['xdg-open', [url]];
  try { spawn(cmd, args, { stdio: 'ignore', detached: true }).unref(); } catch { /* the address is printed too */ }
};

/** Sets a secret with the value on gh's standard input, never on its command line. */
const defaultSetSecret = (fullName, name, value) => {
  execFileSync('gh', ['secret', 'set', name, '--repo', fullName], { input: value, stdio: ['pipe', 'ignore', 'ignore'] });
};

async function trade(code, fetchFn) {
  const res = await fetchFn(`${API}/app-manifests/${encodeURIComponent(code)}/conversions`, { method: 'POST', headers: { accept: 'application/vnd.github+json' } });
  if (!res.ok) return undefined;
  const b = await res.json();
  return b && b.id && b.pem && b.slug ? { id: b.id, pem: b.pem, slug: b.slug } : undefined;
}

async function queueIdentity({ repo, org, out = process.stdout, cwd = process.cwd(), fetchFn = fetch, setSecret = defaultSetSecret, open = defaultOpen, timeoutMs = 10 * 60 * 1000, onListening } = {}) {
  const fullName = repo || remoteRepo(cwd);
  if (!fullName || !/^[^/\s]+\/[^/\s]+$/.test(fullName)) {
    out.write('Name the repository: sipnship queue-identity --repo OWNER/NAME\n');
    return 2;
  }
  const state = crypto.randomBytes(16).toString('hex');
  let finish;
  const done = new Promise((r) => { finish = r; });
  let base = '';
  const server = http.createServer(async (req, res) => {
    const u = new URL(req.url, base || 'http://127.0.0.1');
    const send = (status, html) => { res.writeHead(status, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' }); res.end(html); };
    if (u.pathname === '/') return send(200, startPage(fullName, JSON.stringify(manifest(fullName, `${base}/done`)), state, org));
    if (u.pathname !== '/done') return send(404, page('Not here', '<p>Nothing here.</p>'));
    if (u.searchParams.get('state') !== state || !u.searchParams.get('code')) return send(400, page('Not the same visit', '<p>That did not come from this visit. Run the command again.</p>'));
    let app;
    try { app = await trade(u.searchParams.get('code'), fetchFn); } catch { app = undefined; }
    if (!app) { send(502, page('GitHub did not answer', '<p>GitHub would not hand the App over. Run the command again.</p>')); return finish({ code: 1, say: 'GitHub would not hand the App over. Nothing was set; run the command again.' }); }
    try {
      setSecret(fullName, 'QUEUE_APP_ID', String(app.id));
      setSecret(fullName, 'QUEUE_APP_KEY', app.pem);
    } catch {
      send(500, page('Not saved', '<p>The secrets could not be set. Is gh signed in to an account that can change this repository?</p>'));
      return finish({ code: 1, say: `The App was made, but its secrets could not be set on ${fullName}. Sign in with gh and delete the App on GitHub to try again; its key was not kept anywhere.` });
    }
    app.pem = '';
    const install = `https://github.com/apps/${app.slug}/installations/new`;
    send(200, page('The queue has its App', `<h1>The queue has its App</h1><p>Its two secrets are set. One step is left: install it on ${esc(fullName)}.</p><p><a href="${esc(install)}">Install the App</a></p>`));
    open(install);
    return finish({ code: 0, say: `Set QUEUE_APP_ID and QUEUE_APP_KEY on ${fullName}. Install the App on that repository to finish: ${install}` });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${server.address().port}`;
  if (onListening) onListening(base);
  out.write(`Opening ${base} to make the queue's App. Click the button there, then Create GitHub App on GitHub's page.\n`);
  open(base);
  const timer = setTimeout(() => finish({ code: 1, say: 'Nothing came back in ten minutes. Run the command again when you are ready.' }), timeoutMs);
  const result = await done;
  clearTimeout(timer);
  server.close();
  out.write(`${result.say}\n`);
  return result.code;
}

module.exports = { queueIdentity, manifest };

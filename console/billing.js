'use strict';
/**
 * How the runtime signed in, for the session report (spec 005, "Agent tokens:
 * a plan is not a key"): on a flat plan, on a metered key, or not known. Reads
 * only whether a key is set and the plan's name from the runtime's own config;
 * never a key, a token or an account name, and never sends more than the word.
 */
const fs = require('fs');
const os = require('os');
const path = require('path');

/** A plan's name as the runtime's config spells it, in the words people use; a name that is not one plain word is left out. */
const PLANS = { max: 'Max', pro: 'Pro', team: 'Team', enterprise: 'Enterprise', free: 'Free' };

function planNameOf(type) {
  const t = String(type || '').toLowerCase();
  if (PLANS[t]) return PLANS[t];
  return /^[a-z]{2,20}$/.test(t) ? t[0].toUpperCase() + t.slice(1) : undefined;
}

/**
 * Claude Code's sign-in: a key in the environment is a key; otherwise a
 * subscription sign-in in its credentials file is a plan, named by its
 * subscription type; otherwise not known (the config is kept elsewhere, or
 * unreadable). The result is { billing } or { billing, planName }.
 */
function claudeSignIn({ env = process.env, home = os.homedir() } = {}) {
  if (env.ANTHROPIC_API_KEY || env.ANTHROPIC_AUTH_TOKEN) return { billing: 'key' };
  try {
    const j = JSON.parse(fs.readFileSync(path.join(home, '.claude', '.credentials.json'), 'utf8'));
    const oauth = j && j.claudeAiOauth;
    if (oauth && typeof oauth === 'object') {
      const planName = planNameOf(oauth.subscriptionType);
      return planName ? { billing: 'plan', planName } : { billing: 'plan' };
    }
  } catch { /* no readable config: not known */ }
  return { billing: 'unknown' };
}

module.exports = { claudeSignIn, planNameOf };

'use strict';
// The listener's question, asked in a window on the machine's own screen
// (spec 012, "The listener"; spec 015, decision 3). An agent that runs a
// command from its shell can type into a terminal prompt but cannot press a
// button on a screen it does not see, so the answer is always a person's,
// at the machine. The default is No: Enter, closing the window and every
// failure mean No. With no screen to show it on (a session over SSH, a
// machine with no desktop, a system with no window tool) nothing is asked and
// the answer is No.

const { spawnSync } = require('child_process');

const SENTENCE = 'Let this machine carry out what you ask from the dashboard? It only does what you approve there, one thing at a time.';

function titleFor(machine) {
  return `Let ${machine || 'this machine'} carry out what you ask?`;
}

// Whether there is a screen a person could be looking at.
function hasScreen(env = process.env, platform = process.platform) {
  if (env.SSH_CONNECTION || env.SSH_CLIENT || env.SSH_TTY) return false;
  // A build or test run has no person at the screen to answer.
  if (env.CI || env.GITHUB_ACTIONS) return false;
  if (platform === 'win32') return true;
  if (platform === 'darwin') return true;
  return !!(env.DISPLAY || env.WAYLAND_DISPLAY);
}

const psQuote = (s) => `'${String(s).replace(/'/g, "''")}'`;

// The one command that shows the window and prints Yes or No; null when this system has none.
function windowCommand(title, text, platform = process.platform) {
  if (platform === 'win32') {
    const script = [
      'Add-Type -AssemblyName System.Windows.Forms',
      '[System.Windows.Forms.Application]::EnableVisualStyles()',
      `$r = [System.Windows.Forms.MessageBox]::Show(${psQuote(text)}, ${psQuote(title)}, 'YesNo', 'Question', 'Button2', 'DefaultDesktopOnly')`,
      "if ($r -eq 'Yes') { 'Yes' } else { 'No' }",
    ].join('; ');
    return { cmd: 'powershell', args: ['-NoProfile', '-NonInteractive', '-Command', script] };
  }
  if (platform === 'darwin') {
    const q = (s) => `"${String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
    return { cmd: 'osascript', args: ['-e', `button returned of (display dialog ${q(text)} with title ${q(title)} buttons {"No", "Yes"} default button "No" cancel button "No")`] };
  }
  return null;
}

// askWindow({ machine }) -> true only when a person at the machine pressed Yes.
// `run` and `screen` are injected so tests show no window.
function askWindow({ machine, env = process.env, platform = process.platform, run, screen } = {}) {
  const shown = screen === undefined ? hasScreen(env, platform) : screen;
  if (!shown) return false;
  const c = windowCommand(titleFor(machine), SENTENCE, platform);
  if (!c) return false;
  const exec = run || ((cmd, args) => {
    const r = spawnSync(cmd, args, { encoding: 'utf8', timeout: 10 * 60000, stdio: ['ignore', 'pipe', 'ignore'], windowsHide: false });
    return { status: r.status === null ? -1 : r.status, stdout: r.stdout || '' };
  });
  try {
    const r = exec(c.cmd, c.args);
    return r.status === 0 && String(r.stdout).trim() === 'Yes';
  } catch {
    return false;
  }
}

module.exports = { askWindow, hasScreen, windowCommand, titleFor, SENTENCE };

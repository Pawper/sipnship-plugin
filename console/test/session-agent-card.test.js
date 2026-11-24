'use strict';
const test = require('node:test');
const assert = require('node:assert');
const sessions = require('../sessions');

test('a number the brief says to leave alone is not the agent\'s work', () => {
  const brief = 'Rework the watering reminders (#1774, #1752).\nLeave #1749 alone; it is another agent\'s.\nDo not touch #1500.';
  assert.deepStrictEqual(sessions.issuesIn(brief), [1774, 1752]);
});

test('the issues its pull request closes still come first', () => {
  assert.deepStrictEqual(sessions.issuesIn('Closes #12. Also see #9, and hands off #7.'), [12]);
});

test('an agent with no worktree of its own is on the branch it pushed, from the folder it pushed from', () => {
  const got = sessions.pushedIn('git -C /work/rooftop-garden/worktrees/frost push -u origin issue-12-frost');
  assert.deepStrictEqual(got, { branch: 'issue-12-frost', tree: '/work/rooftop-garden/worktrees/frost' });
  assert.strictEqual(sessions.pushedIn('git push origin main'), undefined);
});

test('a redirect on a push command is never taken for the branch', () => {
  const got = sessions.pushedIn('git -C /work/rooftop-garden/worktrees/frost push -u origin issue-12-frost 2>&1');
  assert.deepStrictEqual(got, { branch: 'issue-12-frost', tree: '/work/rooftop-garden/worktrees/frost' });
  assert.strictEqual(sessions.pushedIn('git push -u origin HEAD 2>&1'), undefined);
  assert.deepStrictEqual(sessions.pushedIn('git push origin frost >> push.log'), { branch: 'frost', tree: undefined });
  assert.strictEqual(sessions.pushedIn('git push origin 2>&1 >/dev/null'), undefined);
});

# Privacy

This plugin collects nothing. It has no server, no account, no analytics and no telemetry, and it sends nothing to its author or to anyone else.

## What it reads, and where that goes

Everything runs on your machine, inside your Claude Code session or your own terminal.

- **The hooks** read the tool call Claude is about to make (a command, a file path, an agent dispatch) to decide whether to refuse it. They print one sentence back into the session; a refusal also adds one line to the hook log below.
- **The session brief and the drive's plan** read your repository with `git` and your project's pull requests and issues with the GitHub CLI, using the GitHub sign-in you already have. The result is printed into your session. The plugin stores none of it.
- **The owner console** reads `console/services.json` and checks which settings are present in your environment and your `.env` file. It reads only whether a setting is set, never its value, and it never prints a variable name or a value on the page. The local mount serves the page on your own machine only.
- **The hook log and what followed.** When a hook refuses a command, it adds one line to `.scratch/hooks.log` inside your project: the time, the hook's name and the session's id, never the command. A small hook then reads the session's next few tool calls on your machine and writes one word to `.scratch/hooks-resolved.log` saying what happened (followed, asked, retried, moved on, stopped, or a possible workaround), again never the command. The owner console shows both. The files stay in the project's ignored scratch folder on your machine; `HOOK_LOG=0` turns it all off.
- **The console's Delivery section** reads your project's CI runs, pull requests and main's history from GitHub with your own sign-in, and the queue and hook logs on your machine, to show how work moves. It keeps the reads in memory for a few minutes and writes nothing.
- **The board, sync, audit and merge queue scripts** call GitHub through the GitHub CLI or GitHub Actions with your own credentials, to do what their names say on your own repository.

## What leaves your machine

Only what you already send by using Claude Code and GitHub: the hook messages and the brief become part of your Claude Code session, which is covered by Anthropic's privacy policy, and the GitHub calls go to GitHub under GitHub's. The plugin adds no other destination.

## Questions

Open an issue at https://github.com/Pawper/sipnship-plugin/issues.

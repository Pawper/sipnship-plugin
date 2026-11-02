# Privacy

Until you connect a machine, this plugin collects nothing. It has no account, no analytics and no telemetry, and it sends nothing to its author or to anyone else. Once you connect a machine to the SipNShip dashboard, it sends the things listed under "Once you connect a machine" below, and only to the dashboard you connected it to. You can turn that off at any time.

## What it reads, and where that goes

Everything runs on your machine, inside your Claude Code session or your own terminal.

- **The hooks** read the tool call Claude is about to make (a command, a file path, an agent dispatch) to decide whether to refuse it. They print one sentence back into the session; a refusal also adds one line to the hook log below.
- **The session brief and the drive's plan** read your repository with `git` and your project's pull requests and issues with the GitHub CLI, using the GitHub sign-in you already have. The result is printed into your session. The plugin stores none of it.
- **The owner console** reads `console/services.json` and checks which settings are present in your environment and your `.env` file. It reads only whether a setting is set, never its value, and it never prints a variable name or a value on the page. The local mount serves the page on your own machine only.
- **The hook log and what followed.** When a hook refuses a command, it adds one line to `.scratch/hooks.log` inside your project: the time, the hook's name and the session's id, never the command. A small hook then reads the session's next few tool calls on your machine and writes one word to `.scratch/hooks-resolved.log` saying what happened (followed, asked, retried, moved on, stopped, or a possible workaround), again never the command. The owner console shows both. The files stay in the project's ignored scratch folder on your machine, and only the fixed words, times and counts described under "Once you connect a machine" ever leave it, and only after you connect; `HOOK_LOG=0` turns it all off.
- **The console's Delivery section** reads your project's CI runs, pull requests and main's history from GitHub with your own sign-in, and the queue and hook logs on your machine, to show how work moves. It keeps the reads in memory for a few minutes and writes nothing.
- **The board, sync, audit and merge queue scripts** call GitHub through the GitHub CLI or GitHub Actions with your own credentials, to do what their names say on your own repository.

## What leaves your machine

Until you connect a machine, only what you already send by using Claude Code and GitHub: the hook messages and the brief become part of your Claude Code session, which is covered by Anthropic's privacy policy, and the GitHub calls go to GitHub under GitHub's. The plugin adds no other destination. After you connect a machine, the one added destination is the SipNShip service, for what "Once you connect a machine" lists.

## Once you connect a machine

Nothing here is sent until you run `npx sipnship connect --repo` on a machine and approve the code it shows on the dashboard. Connecting is the one switch; a machine that was never connected sends nothing.

**What is sent, to where.** After each session brief, and at the end of each merge queue drain, the plugin sends one small message to the SipNShip service (`sipnship.dev`, or the address in `SIPNSHIP_URL`), signed with a token that belongs to that repository and that machine alone. The token only lets the machine write its own brief and its own rule reports, and read its own approved requests; it cannot read anything else. The brief carries:

- the machine's name and the time it was sent;
- the brief's own cards, as sentences: how many pull requests are open or waiting, which checks failed, what landed, with the names of branches, checks and workflows;
- the runner watch's latest sample: cores, runners, how many are busy, how long jobs waited and ran, and the load and memory figures the watch read;
- the lines of your manual's "Steps for the owner" list, as written;
- a sample of the agent sessions on that machine in the last two hours: when each started, the model's name, the branch and worktree folder name, the issue numbers its first message names, the first twelve words of its last message, and the token counts the agent runtime reported, with the kind of work when the drive noted one;
- the models you declared as local in your services file, by name;
- the answers your agent gave to questions the dashboard asked it, in one sentence each;
- which kinds of request this machine's listener carries out, while the listener is on (see below).

**What agents did after a rule stopped them.** Once a refusal in the hook log has settled, the plugin also sends one small report for it, at the end of the agent's turn (and with the next brief when an earlier send did not get through): the name of the hook that refused, when it did, one word for what came next (followed, asked, retried, moved on, stopped, or a possible workaround), the seconds and the number of tool calls (0 to 5) it took, for a possible workaround only the kind of tool behind it (shell, file edit, agent or other), the issue numbers the session was working on when the session sample already knows them, and a key that groups one session's refusals, the first 16 characters of a hash of the session's id and the repository's id, which cannot be turned back into the id. Never the command, a file path, a prompt, an argument or any text, and never the hook's reply. The service refuses a whole report that holds any field or value outside those lists. It is on by default once a machine is connected, can be switched off per repository in the dashboard's Settings, and `HOOK_LOG=0` on the machine turns it and the hook log off. The plugin keeps `.scratch/hooks/sent`, the last report the service acknowledged; a failed send is carried by the next turn's end or the next brief, never retried in a loop.

**What is never sent.** File contents, diffs, command text, log text (the rule reports above are fixed words, times and counts, not log text), environment values, secrets, passwords and tokens. A message over 64 KB is not sent at all. A send that fails is dropped and replaced by the next one, never replayed, and it never slows a session or a merge.

**How to turn it off.** Run `npx sipnship disconnect --repo` on the machine: it tells the service to stop that machine's token and forgets the token here, and nothing more is sent. The Disconnect button on the dashboard does the same from there, and the machine's next send is refused. The token is kept in `~/.sipnship/tokens.json` (or under `$SIPNSHIP_HOME`), outside every repository, readable by you only.

**The listener, off until you turn it on.** `npx sipnship listen` is a separate, optional process that carries out requests you approve on the dashboard: add or remove a build runner, grant your agent its permissions, run a database change, start a deploy, and let the antivirus skip, or scan again, the runner folders. It is off after connecting. Only you can turn it on, on that machine, by answering Yes to the question at the end of `connect --repo` or running `npx sipnship listen on`; the dashboard cannot turn it on, and `npx sipnship listen off` or Disconnect stops it. While it is on it asks the service, every two minutes, for the requests approved for that machine, and receives for each one only a kind from a fixed list, one checked parameter (a runner's name, a permission's id, `main` or a pull request's number), who asked and who approved it, and when. It checks each again before running anything, runs only that kind's fixed script from your repository or this plugin, and reports back each step with the kind's own facts only (a runner's name, a pull request's number, a workflow run's number, the folders set), never log or command text. Windows still asks you, on the machine's own screen, before anything runs as administrator. It writes one line per request (when, kind, who asked, who approved, outcome) to `~/.sipnship/requests.log` on your machine, which stays there until you clear it.

## Questions

Open an issue at https://github.com/Pawper/sipnship-plugin/issues.

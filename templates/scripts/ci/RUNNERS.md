# Self-hosted runners

A runner that fails quietly costs more than a slow one: every check sits queued or fails for no reason anyone can see. These are the rules that keep that from happening.

## Install each runner as a service

A runner started by hand in a terminal stops when the terminal closes, the user logs out, or the machine restarts, and nothing says so. Install it as a Windows service instead. `scripts/ci/add-runner.ps1 -Name NAME` does the whole thing: registration token, download, configuration with the labels the workflows expect, service install and start. A runner installed by hand can be moved over with `config.cmd remove`, then the script.

The script needs an elevated PowerShell, because installing a service does, and it refuses to run without one. An agent can launch the elevated shell and the owner clicks the prompt once:

```powershell
Start-Process powershell -Verb RunAs -Wait -ArgumentList '-ExecutionPolicy Bypass -File scripts\ci\add-runner.ps1 -Name build-2'
```

Each repository's runners live under their own root, `C:\actions-runner-<repo>`, so a second project's runner never lands inside the first project's runner folder; `-Root` overrides it.

The service runs as NETWORK SERVICE, which sees only the machine PATH, not your user PATH. Git, Node and gh must be on the machine PATH. The doctor checks that. The doctor also knows when every runner on the machine is a service: the two warnings that only apply to a runner started by hand (the `NoDefaultCurrentDirectoryInExePath` variable and the execution policy) become notes.

## The shell every step runs in

A PowerShell step names its own execution policy: `shell: powershell -NoProfile -ExecutionPolicy Bypass -Command ". '{0}'"`. A bare `shell: powershell` runs the step's script under the machine's policy, and a machine set to AllSigned refuses it ("is not digitally signed"). The doctor warns about an AllSigned or Restricted machine policy.

On a Windows runner the service account's `bash` and `sh` resolve to the WSL stub, and every step fails before it starts. `ci.yml` and `queue-drain.yml` carry a `RUN_SHELL` placeholder in their workflow-level `defaults.run.shell`; on Windows runners set it to Git's bash by its short path, `'C:\PROGRA~1\Git\bin\bash.exe --noprofile --norc -eo pipefail {0}'`, and on hosted runners to `bash`. A PowerShell step says `shell: powershell`, never `pwsh`: PowerShell 7 from the Store lives in a user folder the service cannot see. The gh-only workflows (audit, board sync, state label, runner watch) stay on hosted runners and keep `shell: sh`.

## How many: `.claude/runners.json`

`"runners": 3` is the default and the project's choice: two so a pull request's jobs run side by side, one a merge-queue drain may hold while it waits for CI. One suits a quiet project that accepts waiting. Four or more when the watch keeps saying jobs waited while the processor idled. The bootstrap installs that many; the doctor and the session brief say when fewer are registered or online; `add-runner.ps1 -Name NAME` adds one and `remove-runner.ps1 -Name NAME` takes one away (both need the elevated prompt; the folder is moved aside, never deleted). Change the number in the file when you change the count.

The machine, not the count, is the real limit. An idle runner holds about 90 MB of memory and almost no processor (one open request to GitHub at a time); a job's worker exists only while the job runs. What grows is disk: every runner keeps its work folder (the checkout, packages, build output). On a personal account a runner serves one repository, so a studio's projects each need their own, and fifteen on one machine is fine while they are idle.

## The watch runs here

`scripts/ci/runner-watch.sh` runs every fifteen minutes as a scheduled task on the runners' machine (`powershell -ExecutionPolicy Bypass -File scripts\ci\runner-watch-install.ps1`, once, as the signed-in user, no admin; `-Remove` takes it away; cron elsewhere). It spends no hosted minutes and sees what a hosted job cannot: the machine's processor, memory, free disk where the runners work, jobs running, how long jobs waited for a runner lately, and every project's runners on this machine. It keeps a day of samples under `~/.sipnship/runner-watch/` and says one plain line on the issue labeled `audit` when a condition starts and when it ends, never on every run:

- jobs waited while the processor idled: one more runner would help;
- jobs waited while the processor was saturated: more runners would slow each job; fewer runners, or a second machine;
- memory above 90%, with the runner count;
- free disk below 15 GB (urgent below 5), where the runners' work folders are;
- more runners than half the cores across the projects on this machine;
- a runner offline, fewer registered than `runners.json` wants, or a run queued over ten minutes.

`sh scripts/ci/runner-watch.sh --print` shows what it sees without writing or commenting. The session brief repeats the conditions that hold. The trade of nothing hosted: when the machine itself is off, nothing reports it; the brief and the queue say "no runner online", which is the same fact from the other side. A project that wants the hosted copy as well sets the repository variable `RUNNER_WATCH_HOSTED` to `yes`.

## Run two

One runner is a queue of one: a slow job makes every other job wait, and when it goes offline everything stops. Run at least two, on the same machine or on two. Each is one run of `add-runner.ps1` with a different name.

## Keep the runner's environment clean

A runner picks up whatever environment it starts with, and so does every job it launches. Keep tool settings out of the machine environment and out of the runner's `.env` file; set what a job needs in the workflow's `env:` block, where it is visible and scoped to that job. The `Runner check` workflow prints what a job actually sees.

**The one that bit a real project: `NoDefaultCurrentDirectoryInExePath`.** Git Bash sets it to 1. A runner started with `run.cmd` from a Git Bash window inherits it, and so does every job. With it set, the Windows command prompt will not run a program from the current folder by its bare name. An Android step that ran `gradlew.bat` failed with "'gradlew.bat' is not recognized as an internal or external command", while the `if not exist gradlew.bat` check just before it passed, because that looks for a file, not a program. Three fixes, any one of which holds:

1. **Run the runner as a service** (`add-runner.ps1`). A service never inherits a shell's environment. This is the fix.
2. **Call programs from the repository with a path**: `.\gradlew.bat`, not `gradlew.bat`. That works whatever the setting, and is right in the workflow regardless.
3. **Clear it at the start of a cmd step**: `set NoDefaultCurrentDirectoryInExePath=`.

To start a runner by hand from Git Bash anyway, strip it first: `env -u NoDefaultCurrentDirectoryInExePath cmd //c run.cmd`. The doctor warns when the shell you run it from sets the variable.

## How many runners

Each runner runs one job at a time, so a CI run's length is roughly its number of jobs divided by the runners, times a job's length. Ten jobs on two runners is five jobs deep: most of the wall time is jobs queued, not tests running. The queue says so while it waits ("6 jobs queued, 2 of 2 runners busy; about 12 minutes"). When queue time dominates, add a runner with `add-runner.ps1`, or trim jobs a change does not need; `QUEUE_JOB_MINUTES` sets the queue's estimate of one job's length.

## Nobody stops the daemon

A build daemon (Gradle's, Nx's, the .NET build server) is one process for every build on the machine. On a machine that also hosts a runner, an agent that runs `gradlew --stop` from its worktree, meaning to tidy up, kills the runner's daemon mid-build, and the android job fails with "Gradle build daemon has been stopped". The `block-loose-ends` hook refuses `gradlew --stop`, `gradle --stop`, `nx reset`, `nx daemon --stop` and `dotnet build-server shutdown`. Stopping what you started means your own servers and watchers; a daemon idles out on its own. If no runner is on the machine, `DAEMON_STOP_OK=1` in front of the command says so.

## Before the first run, and after any change to the machine

1. `sh scripts/ci/runner-doctor.sh` on the machine: which bash a step gets, whether Git, Node and gh are on the machine PATH, whether the shell you are in would leak `NoDefaultCurrentDirectoryInExePath` into a runner, PowerShell's execution policy, and whether each runner is online.
2. The `Runner check` workflow from the Actions tab: Git's bash named by path, a PowerShell step, the tools the job sees, and a cmd step that says whether jobs inherited `NoDefaultCurrentDirectoryInExePath` and runs a program from the current folder by path.

## When it goes wrong anyway

`Runner watch` on a hosted runner runs only when `RUNNER_WATCH_HOSTED` is `yes` (see "The watch runs here"); then it works when ours are down. It comments on the issue labeled `audit` when a runner is offline, when fewer than two are online, or when any run has sat queued for more than ten minutes, and says nothing otherwise. The merge queue also says "GitHub Actions is down, not your code" when the hosted side is the problem, so the two are never confused.

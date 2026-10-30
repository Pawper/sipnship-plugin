#!/bin/sh
# Check a self-hosted runner machine before any run. Run it on the machine,
# from the project folder: sh scripts/ci/runner-doctor.sh
#
# It prints one line per check, "ok" or "warn", and ends with a count. The
# checks are the ones that cost a real project four tries: the wrong bash
# on PATH, Node and Git not findable from the service's PATH, PowerShell's
# execution policy, and the runner itself offline.
here=$(dirname "$0")
. "$here/doctor-lib.sh"
. "$here/run-lib.sh"

warns=0
say() { echo "$1  $2"; [ "$1" = warn ] && warns=$((warns + 1)); }
note() { echo "note  $1"; }

# Are the runners on this machine services? A service never inherits a
# shell's environment or policy, so two of the checks below are notes,
# not things to fix, when every runner here is one.
services=0
if [ -n "$WINDIR" ]; then
  services=$(sc query type= service state= all 2>/dev/null | grep -ci 'SERVICE_NAME: actions.runner' || true)
fi

# 1. Which bash a step would get.
bash_path=$(command -v bash 2>/dev/null || echo "")
say "$(bash_verdict "$bash_path")" "bash on PATH: ${bash_path:-none}$(printf '%s' "$bash_path" | grep -qi 'system32' && printf ' (that is WSL; name Git'\''s bash by path in the workflow)')"

# 2. Tools on the machine PATH, which is what the runner service sees.
machine_path=""
if [ -n "$WINDIR" ]; then
  # MSYS_NO_PATHCONV keeps Git Bash from turning "/v" into a drive path.
  machine_path=$(MSYS_NO_PATHCONV=1 reg query 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' /v Path 2>/dev/null | awk '/REG_/ { sub(/^[ \t]*Path[ \t]+REG_[A-Z_]+[ \t]+/, ""); print }' | tail -n 1 | tr -d '\r')
fi
for tool in git node gh; do
  found=$(command -v "$tool" 2>/dev/null || echo "")
  if [ -z "$found" ]; then say warn "$tool: not on this shell's PATH"; continue; fi
  if [ -n "$machine_path" ]; then
    # The Windows path of the tool, so a Git Bash alias like /mingw64/bin
    # compares against the machine PATH as C:\Program Files\Git\mingw64\bin.
    win_found=$(cygpath -w "$found" 2>/dev/null || printf '%s' "$found")
    verdict=$(tool_on_machine_path "$win_found" "$machine_path")
    # Git Bash resolves a tool to its own folder; the service finds it
    # through another entry (Git\cmd for git). Look for it in every entry.
    if [ "$verdict" = warn ]; then
      printf '%s' "$machine_path" | tr ';' '\n' | while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        u=$(cygpath -u "$entry" 2>/dev/null || printf '%s' "$entry")
        for ext in "" .exe .cmd .bat; do if [ -x "$u/$tool$ext" ]; then echo found; break; fi; done
      done | grep -q found && verdict=ok
    fi
    say "$verdict" "$tool: $found$( [ "$verdict" = warn ] && printf ' (not on the machine PATH, so the runner service may not find it)')"
  else
    say ok "$tool: $found"
  fi
done

# 2b. A variable this shell sets that a runner must never inherit.
ev=$(exepath_verdict "$NoDefaultCurrentDirectoryInExePath")
if [ "$ev" = warn ] && [ "${services:-0}" -gt 0 ]; then
  note "this shell sets NoDefaultCurrentDirectoryInExePath=1, which does not reach the $services runner service(s) on this machine; it would matter only for a runner started by hand from this shell"
elif [ "$ev" = warn ]; then
  say warn "this shell sets NoDefaultCurrentDirectoryInExePath=1 (Git Bash does). Never start run.cmd from it: every job would inherit it, and cmd would refuse to run gradlew.bat or any program from the current folder by its bare name. Install the runner as a service, or start it with: env -u NoDefaultCurrentDirectoryInExePath cmd //c run.cmd"
else
  say ok "NoDefaultCurrentDirectoryInExePath is not set in this shell"
fi

# 3. PowerShell execution policy.
if command -v powershell >/dev/null 2>&1; then
  pol=$(powershell -NoProfile -Command 'Get-ExecutionPolicy -List | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }' 2>/dev/null | tr '\r\n' '  ')
  # A step shell of bare "powershell" runs under this policy too; only a
  # shell line that names -ExecutionPolicy Bypass escapes it.
  say "$(policy_verdict "$pol")" "execution policy: $pol$( [ "$(policy_verdict "$pol")" = warn ] && printf ' (a machine policy of Restricted or AllSigned refuses every PowerShell step whose shell line does not name its own: shell: powershell -NoProfile -ExecutionPolicy Bypass -Command ". '"'"'{0}'"'"'")')"
fi

# 3b. PowerShell 7 from the Store lives in the user's WindowsApps folder,
# which the service cannot see, so a "shell: pwsh" step fails there.
if [ -n "$WINDIR" ]; then
  pw=$(command -v pwsh 2>/dev/null || echo "")
  case "$pw" in
    "") note "pwsh: not installed; workflow steps use \"shell: powershell\", which is always there" ;;
    *WindowsApps*|*windowsapps*) say warn "pwsh: $pw is a Store install in a user folder the runner service cannot see; use \"shell: powershell\" in workflow steps, or install PowerShell 7 with the MSI" ;;
    *) say ok "pwsh: $pw" ;;
  esac
fi

# 4. The runner, as GitHub sees it.
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  runners=$(gh api 'repos/{owner}/{repo}/actions/runners' --jq '.runners[] | [.name, .status, (.busy | tostring), ([.labels[].name] | join(","))] | @tsv' 2>/dev/null)
  if [ -z "$runners" ]; then say warn "runners: none registered for this repository"; else
    printf '%s\n' "$runners" | while IFS="$(printf '\t')" read -r name status busy labels; do
      [ "$status" = online ] && echo "ok    runner $name: online, busy=$busy, labels $labels" || echo "warn  runner $name: $status"
    done
    offline=$(printf '%s\n' "$runners" | awk -F'\t' '$2 != "online"' | wc -l | tr -d ' ')
    warns=$((warns + offline))
    # Judged from what GitHub has registered and this machine's cores; the
    # repository holds no count.
    cores=$(machine_cores)
    have=$(printf '%s\n' "$runners" | grep -c .)
    say "$( [ "$have" -lt 2 ] && echo warn || echo ok )" "runners: $(runner_status "$(printf '%s\n' "$runners" | cut -f1-3)" "$cores")$( [ "$have" -lt 2 ] && printf ' (one runner makes every job wait for the last; add one with scripts/ci/add-runner.ps1)')"
    keynote=$(runner_key_note "$(cat .claude/runners.json 2>/dev/null)")
    [ -n "$keynote" ] && note "$keynote"
  fi
else
  say warn "runners: gh is not signed in, so the registered runners could not be listed"
fi

echo
if [ "$warns" -eq 0 ]; then echo "Everything a run needs is in place.${services:+ ($services runner service(s) found.)}"; else echo "$warns thing(s) to fix before a run on this machine."; exit 1; fi

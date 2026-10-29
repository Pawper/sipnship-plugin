#!/bin/sh
# The runner watch, on the machine the runners share. Runs every fifteen
# minutes from a scheduled task (scripts/ci/runner-watch-install.ps1 sets
# it up; cron elsewhere), needs no admin and no hosted minutes, and sees
# what a hosted job never could: the machine's own load.
#
# Each run reads the runners and stuck runs from GitHub, samples the
# machine (processor, memory, free disk where the runners work, jobs
# running, how long jobs waited for a runner lately, every project's
# runners on this machine), keeps a day of samples under the user's
# folder, and says in one plain line when a condition starts or ends:
# on the issue labeled audit, and in the file the session brief reads.
# It never says the same thing twice (constitution: nothing nags).
#
# Usage, from the project root: sh scripts/ci/runner-watch.sh [--print]
#   --print  sample and print the verdicts; write and comment nothing
here=$(dirname "$0")
. "$here/run-lib.sh"
print_only=no; [ "$1" = --print ] && print_only=yes
command -v gh >/dev/null 2>&1 || { echo "gh is not installed; the watch needs it to read the runners." >&2; exit 2; }
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || git remote get-url origin 2>/dev/null | sed 's#.*github.com[:/]##; s#\.git$##')
[ -n "$repo" ] || { echo "Not in a GitHub repository." >&2; exit 2; }
want=$(runner_count "$(cat .claude/runners.json 2>/dev/null)")
home=${SIPNSHIP_HOME:-$HOME/.sipnship}
dir="$home/runner-watch"; mkdir -p "$dir" 2>/dev/null || true
key=$(printf '%s' "$repo" | tr '/' '-')
now=$(date +%s)

# 1. The runners, as GitHub sees them.
runners=$(gh api "repos/$repo/actions/runners" --jq '.runners[] | [.name, .status, (.busy | tostring)] | @tsv' 2>/dev/null | tr -d '\r')
status=$(runner_status "$runners" "$want")
jobs=$(printf '%s\n' "$runners" | awk -F'\t' '$3 == "true"' | grep -c . || true)

# 2. Runs queued too long, and how long jobs waited for a runner lately.
runs=$(gh api "repos/$repo/actions/runs?per_page=40" --jq '.workflow_runs[] | [.id, .name, .head_branch, .status, (.created_at | fromdate), ((.run_started_at // .created_at) | fromdate)] | @tsv' 2>/dev/null | tr -d '\r')
stuck=$(stuck_runs "$(printf '%s\n' "$runs" | cut -f1-5)" "$now" 10)
wait_min=$(printf '%s\n' "$runs" | awk -F'\t' 'NF >= 6 && $4 == "completed" { s += ($6 - $5); n++ } END { if (n > 0) printf "%d", (s / n) / 60; else print 0 }')

# 3. The machine.
sample_machine() {
  if [ -n "$WINDIR" ]; then
    powershell -NoProfile -Command '
      $cpu = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
      $os = Get-CimInstance Win32_OperatingSystem
      $mem = [math]::Round(100 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize * 100))
      $root = if (Test-Path "C:\actions-runner-*") { (Get-Item "C:\actions-runner-*" | Select-Object -First 1).PSDrive.Name } else { "C" }
      $disk = [math]::Round((Get-PSDrive $root).Free / 1GB)
      $here = (Get-Service "actions.runner.*" -ErrorAction SilentlyContinue | Measure-Object).Count
      $cores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
      $busy = (Get-Process Runner.Worker -ErrorAction SilentlyContinue | Measure-Object).Count
      "$([int]$cpu)`t$mem`t$disk`t$here`t$cores`t$busy"' 2>/dev/null | tr -d '\r'
  else
    cpu=$(awk '{ printf "%d", $1 * 100 / '"$(nproc 2>/dev/null || echo 1)"' }' /proc/loadavg 2>/dev/null || echo 0)
    mem=$(free 2>/dev/null | awk '/^Mem:/ { printf "%d", $3 * 100 / $2 }' || echo 0)
    disk=$(df -BG "${HOME:-/}" 2>/dev/null | awk 'NR == 2 { gsub(/G/, "", $4); print $4 }' || echo 0)
    here=$(pgrep -fc Runner.Listener 2>/dev/null || echo 0)
    cores=$(nproc 2>/dev/null || echo 1)
    busy=$(pgrep -fc Runner.Worker 2>/dev/null || echo 0)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${cpu:-0}" "${mem:-0}" "${disk:-0}" "${here:-0}" "${cores:-1}" "${busy:-0}"
  fi
}
m=$(sample_machine)
cpu=$(printf '%s' "$m" | cut -f1); mem=$(printf '%s' "$m" | cut -f2); disk=$(printf '%s' "$m" | cut -f3); here=$(printf '%s' "$m" | cut -f4); cores=$(printf '%s' "$m" | cut -f5); busy=$(printf '%s' "$m" | cut -f6)
# The machine line: cores, runners here across repositories, busy now (a
# job's worker process), and what one runner per two cores allows.
mline=$(machine_line "${cores:-0}" "${here:-0}" "${busy:-0}")
sample=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "${cpu:-0}" "${mem:-0}" "${disk:-0}" "$jobs" "$wait_min" "${here:-0}" "${cores:-0}")

# 4. What holds now.
verdicts=$(load_verdicts "$sample" "$want")
offline=$(printf '%s\n' "$runners" | awk -F'\t' 'NF >= 2 && $2 != "online" { printf "offline-%s|runner %s is %s\n", $1, $1, $2 }')
total=$(printf '%s\n' "$runners" | grep -c . || true)
short=""; [ "$total" -lt "$want" ] 2>/dev/null && short="short|$status (add one: scripts/ci/add-runner.ps1)"
stuckline=""; [ -n "$stuck" ] && stuckline="stuck|$(printf '%s\n' "$stuck" | grep -c .) run(s) queued for more than ten minutes; no runner is picking them up"
now_lines=$(printf '%s\n%s\n%s\n%s\n' "$verdicts" "$offline" "$short" "$stuckline" | sed '/^$/d')

if [ "$print_only" = yes ]; then
  echo "runners: $status"
  echo "machine: processor ${cpu}%, memory ${mem}%, ${disk} GB free, $jobs job(s) running, jobs waited ${wait_min} min on average, $here runner(s) on this machine, $cores cores"
  echo "machine line: $mline"
  if [ -n "$now_lines" ]; then printf '%s\n' "$now_lines" | sed 's/^[^|]*|/  /'; else echo "nothing to say"; fi
  exit 0
fi

# 5. Keep a day of samples, the state, and the line the brief reads.
printf '%s\t%s\n' "$now" "$sample" >> "$dir/$key.tsv" 2>/dev/null || true
tail -n 96 "$dir/$key.tsv" > "$dir/$key.tsv.new" 2>/dev/null && mv "$dir/$key.tsv.new" "$dir/$key.tsv"
prev=$(cat "$dir/$key.state" 2>/dev/null || true)
changes=$(watch_changes "$prev" "$now_lines")
printf '%s\n' "$now_lines" > "$dir/$key.state"
printf '%s\t%s\n' "$now" "$status" > "$dir/$key.latest"
# The machine line, for the session brief and the console; one per machine.
printf '%s\t%s\t%s\t%s\t%s\n' "$now" "${cores:-0}" "${here:-0}" "${busy:-0}" "$mline" > "$dir/machine.tsv" 2>/dev/null || true

# 6. Say what changed, once.
if [ -n "$changes" ]; then
  printf '%s\n' "$changes"
  tracking=$(gh api "repos/$repo/issues?labels=audit&state=open&per_page=1" --jq '.[0].number' 2>/dev/null)
  if [ -n "$tracking" ]; then
    body="Runner watch, $(date '+%Y-%m-%d %H:%M'):
$(printf '%s\n' "$changes" | sed 's/^/- /')

On the runner machine: sh scripts/ci/runner-watch.sh --print. See scripts/ci/RUNNERS.md."
    printf '%s' "$body" > "$dir/$key.comment"
    gh api "repos/$repo/issues/$tracking/comments" -F body=@"$dir/$key.comment" >/dev/null 2>&1 || echo "Could not comment on the audit issue #$tracking." >&2
  fi
fi
exit 0

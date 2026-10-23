#!/bin/sh
# Pure helpers for keeping the host's build CPU down. Nothing here calls
# git, gh or the network; the deploy workflow, the Vercel ignore step, the
# setup script, the brief and the audit gather the facts and these decide.
#
# Build CPU was nearly all of one owner's Vercel bill: every push to every
# branch was a build, and a multi-agent project pushes many branches, many
# batch branches and many merges to main. Three paths, in order of
# preference: build on the project's own runner and deploy the output
# (runner); a scheduled deploy that Vercel builds (vercel); Git deploys from
# main only, guarded and throttled (guard).

# ships_path PATH APP_ROOT [EXTRA]
# Print "yes" when a change to PATH (relative to the repository root) can
# change what the app ships, "no" when it cannot. APP_ROOT is the app's
# folder ("." for the root). Outside APP_ROOT nothing ships. Inside it, the
# homes the plugin knows never ship: docs, specs, tests, status, design,
# logs, supabase, .github, .claude, .scratch, Markdown, test files, and the
# plugin's own scripts (scripts/ci/, scripts/design/, scripts/*.sh): a
# template sync that touched only those once started a web build and two
# Android builds.
# EXTRA is the project's own, space separated folders inside the app
# ("packs scripts"), from "neverShips" in .claude/deploy.json.
ships_path() {
  printf '%s\n' "$1" | tr '\\' '/' | awk -v root="$2" -v extra="$3" '
    {
      p = $0; r = root; sub(/\/$/, "", r)
      if (r != "" && r != ".") { if (substr(p, 1, length(r) + 1) != r "/") { print "no"; exit } p = substr(p, length(r) + 2) }
      n = split(extra, x, /[ \t,]+/)
      for (i = 1; i <= n; i++) { e = x[i]; sub(/^\.\//, "", e); sub(/\/$/, "", e); if (e != "" && (p == e || substr(p, 1, length(e) + 1) == e "/")) { print "no"; exit } }
      if (p ~ /^(docs|specs|tests?|status|design|logs|supabase|e2e|\.github|\.claude|\.scratch)\//) { print "no"; exit }
      if (p ~ /^scripts\/(ci|design|sync|board|drive)\// || p ~ /^scripts\/[^\/]+\.sh$/) { print "no"; exit }
      if (p ~ /\/(tests?|__tests__|e2e)\//) { print "no"; exit }
      if (p ~ /\.(md|mdx)$/ || p ~ /(^|\/)[^\/]*\.(test|spec)\.[A-Za-z]+$/) { print "no"; exit }
      print "yes"
    }'
}

# deploy_skip PATHS APP_ROOT [EXTRA]
# PATHS is one changed path per line since the last deployed commit. Print
# "skip" when none of them ships, "build" when one does. No paths at all is
# "skip": nothing changed. EXTRA as for ships_path.
deploy_skip() {
  ds_any=no
  ds_list=$(printf '%s\n' "$1" | tr -d '\r')
  while IFS= read -r ds_p; do
    [ -n "$ds_p" ] || continue
    if [ "$(ships_path "$ds_p" "$2" "$3")" = yes ]; then ds_any=yes; break; fi
  done <<EOF
$ds_list
EOF
  if [ "$ds_any" = yes ]; then echo build; else echo skip; fi
}

# deploy_throttle LAST_EPOCH NOW INTERVAL_MINUTES
# Print "build" when the last production deploy was at least the interval
# ago, or is unknown; otherwise "wait N", the minutes left. Skipping loses
# nothing: the next build diffs from the last deployed commit and ships
# everything the skipped ones held.
deploy_throttle() {
  case "$1" in ''|0|*[!0-9]*) echo build; return 0 ;; esac
  dt_left=$(( ${3:-60} * 60 - ($2 - $1) ))
  if [ "$dt_left" -le 0 ]; then echo build; else echo "wait $(( (dt_left + 59) / 60 ))"; fi
}

# deploy_path VERCEL RUNNER SECRETS [HOSTED]
# Each argument is yes or no: the project deploys to Vercel; it has a
# self-hosted runner that is not Windows; the Vercel token, org and project
# ids are set as repository secrets; GitHub's hosted machines are available
# (a private repository may have no hosted minutes; default yes). Print the
# path to set up: runner, vercel, guard, or none when the project does not
# deploy to Vercel.
#
# A Windows runner never takes the runner path: its build cannot write the
# output without Developer Mode, and with it Vercel rejects the upload at
# "Deploying outputs". The scheduled vercel path needs somewhere to run the
# deploy: a hosted machine or a non-Windows runner. Without the secrets, or
# with nowhere to run, only the guard works, and it needs no workflow.
deploy_path() {
  [ "$1" = yes ] || { echo none; return 0; }
  if [ "$3" = yes ] && [ "$2" = yes ]; then echo runner
  elif [ "$3" = yes ] && [ "${4:-yes}" = yes ]; then echo vercel
  else echo guard; fi
}

# runner_os_pick RUNNERS
# RUNNERS is one self-hosted runner per line, "os<TAB>labels" as GitHub
# lists them ("Linux<TAB>self-hosted,Linux,X64"). Print the runs-on value
# for the first runner that is not Windows, as a JSON array
# (["self-hosted","Linux"]), or nothing when every runner is Windows.
runner_os_pick() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' '
    NF >= 1 && $1 != "" && tolower($1) !~ /windows/ { printf "[\"self-hosted\",\"%s\"]\n", $1; exit }'
}

# json_words TEXT KEY
# The strings of a one-line JSON array under KEY, space separated:
# "neverShips": ["packs", "scripts"] gives "packs scripts". Nothing when
# the key is missing.
json_words() {
  printf '%s' "$1" | tr -d '\r\n' | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\\[\\([^]]*\\)\\].*/\\1/p" | tr -d '"' | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//'
}

# json_string TEXT KEY / json_number TEXT KEY
# A top-level string or number from a small JSON file such as
# .claude/deploy.json, without jq, which a self-hosted machine may lack.
json_string() {
  printf '%s' "$1" | tr -d '\r\n' | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p"
}
json_number() {
  printf '%s' "$1" | tr -d '\r\n' | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p"
}

# interval_cron MINUTES
# The cron schedule that runs a deploy at most once per interval: every N
# minutes under an hour, at minute 17 of every N hours from an hour up.
interval_cron() {
  ic_m=${1:-60}
  case "$ic_m" in ''|*[!0-9]*) ic_m=60 ;; esac
  [ "$ic_m" -ge 5 ] || ic_m=5
  if [ "$ic_m" -lt 60 ]; then printf '*/%s * * * *\n' "$ic_m"; return 0; fi
  ic_h=$(( ic_m / 60 ))
  if [ "$ic_h" -le 1 ]; then echo '17 * * * *'; else printf '17 */%s * * *\n' "$ic_h"; fi
}

# rel_to_root APP_ROOT
# The path from APP_ROOT back to the repository root, for the command Vercel
# runs in the app's folder: "" for ".", "../" for "web", "../../" for
# "apps/web".
rel_to_root() {
  printf '%s\n' "$1" | awk '{ r = $0; sub(/\/$/, "", r); if (r == "" || r == ".") { print ""; exit } n = split(r, a, "/"); s = ""; for (i = 1; i <= n; i++) s = s "../"; print s }'
}

# guard_kind VERCEL_JSON
# What a vercel.json holds: "scheduled" when Git deploys are off (paths
# runner and vercel), "plugin" when its ignoreCommand runs the plugin's
# vercel-ignore.sh, "handwritten" when it has some other ignoreCommand or
# limits deploys by branch without one, "none" when it does neither.
guard_kind() {
  gk=$(printf '%s' "$1" | tr -d '\r\n')
  if printf '%s' "$gk" | grep -Eq '"deploymentEnabled"[[:space:]]*:[[:space:]]*false'; then echo scheduled
  elif printf '%s' "$gk" | grep -q 'vercel-ignore\.sh'; then echo plugin
  elif printf '%s' "$gk" | grep -Eq '"ignoreCommand"|"deploymentEnabled"'; then echo handwritten
  else echo none; fi
}

# deploy_health PATH MAIN DEPLOYED OLDEST_EPOCH NOW INTERVAL [LAST_RUN]
# One plain line when the chosen path is not keeping up, nothing when it
# is. MAIN and DEPLOYED are commit shas (DEPLOYED empty when none is
# recorded); OLDEST_EPOCH is when the oldest shipping commit not yet
# deployed landed (empty when there is none); LAST_RUN is the deploy
# workflow's last conclusion, or "fellback" (a runner build that fell back
# to Vercel) or "billing" (GitHub refused to start it on a hosted machine
# for billing). Overdue means older than twice the interval,
# since a scheduled run can land just after a merge.
deploy_health() {
  case "$1" in runner|vercel|guard) ;; *) return 0 ;; esac
  case "$7" in
    billing) echo "Deploys: hosted Actions minutes are used up, so the last Deploy run could not start (GitHub refused it for billing: a payment failed or the spending limit is reached); main is not reaching production. Settle billing at github.com/settings/billing, or move Deploy onto a runner of this project's own."; return 0 ;;
    failure|startup_failure|timed_out) echo "Deploys: the last scheduled deploy failed; main is not reaching production. Open the Deploy workflow's last run."; return 0 ;;
    fellback) echo "Deploys: the last deploy fell back to a build on Vercel because the runner build failed, so it billed Vercel build minutes. Open the Deploy workflow's last run, job build-on-runner."; return 0 ;;
  esac
  if [ -z "$3" ]; then
    [ "$1" = guard ] || echo "Deploys: no deploy is recorded yet; run the Deploy workflow once from the Actions tab."
    return 0
  fi
  [ "$2" != "$3" ] || return 0
  case "$4" in ''|*[!0-9]*) return 0 ;; esac
  dh_age=$(( ($5 - $4) / 60 ))
  dh_iv=${6:-60}; [ "$dh_iv" -ge 30 ] 2>/dev/null || dh_iv=30
  if [ "$dh_age" -ge $(( dh_iv * 2 )) ]; then
    echo "Deploys: main has changes waiting $dh_age minutes that are not in production (the interval is ${6:-60}); check the Deploy workflow and the runner."
  fi
}

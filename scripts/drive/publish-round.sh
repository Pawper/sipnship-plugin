#!/bin/sh
# Publish a round to the dashboard's Work tab: one comment on the open issue
# labeled `drive`, carrying the round as the marker the service reads
# (`<!-- sipnship-proposal {...} -->`). The drive, or a coordinator acting as
# it, runs this when it proposes a round and again when it dispatches it. A
# later comment replaces the earlier one on the tab.
#
# Usage, from the project root:
#   sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/publish-round.sh" [--issue N] [--dry-run] [--no-labels] ROUND_FILE
#
# ROUND_FILE is plain lines. Blank lines and lines starting with # are ignored.
#   status: proposed          proposed (the default) waits for a go-ahead and
#                             draws as "Proposed next round"; started means the
#                             round was dispatched and draws as Working cards
#   unit: 12 14 | why: both change the watering schedule | files: src/schedule.ts, specs/030-watering/ | pr: 531
#                             one agent's work: its issues, then optional
#                             fields; "why" is for a bundle, "files" are the
#                             areas it changes, "pr" is the pull request once
#                             the agent opens it (the unit then belongs to the
#                             Queue and leaves Work)
#   hold: 16 | after: 12 14 | files: src/beds/
#                             work that waits on a running unit, named by that
#                             unit's issues
# No two units may share an issue or a file; the script says so and posts
# nothing. With status started, each unit's issues that have no pull request
# are set to In progress (the state label, over REST; the nightly board sync
# sets the board's field), so a dispatched unit never shows as Ready.
# --issue names the drive issue when more than one is open; --dry-run prints
# the comment and changes nothing; --no-labels leaves the labels alone.
# Everything here is REST. Needs gh signed in.
here=$(dirname "$0")
. "$here/../../hooks/scripts/lib.sh"

issue=""; dry=no; labels=yes; file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) shift; issue=$1 ;;
    --dry-run) dry=yes ;;
    --no-labels) labels=no ;;
    -*) echo "publish-round: unknown option $1" >&2; exit 2 ;;
    *) file=$1 ;;
  esac
  shift
done
[ -n "$file" ] && [ -f "$file" ] || { echo "Usage: publish-round.sh [--issue N] [--dry-run] [--no-labels] ROUND_FILE" >&2; exit 2; }

# The round as JSON and as a plain comment, or the first thing wrong with it.
out=$(awk '
function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/>/, "\\u003e", s); gsub(/<!/, "\\u003c!", s); gsub(/[\t\r]/, " ", s); return s }
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function numlist(s,   n, a, i, out) {
  n = split(trim(s), a, /[ ,#]+/); out = ""
  for (i = 1; i <= n; i++) { if (a[i] == "") continue; if (a[i] !~ /^[0-9]+$/) return "!"; out = out (out == "" ? "" : ",") a[i] }
  return out
}
function arealist(s,   n, a, i, out) {
  n = split(s, a, ","); out = ""
  for (i = 1; i <= n; i++) { a[i] = trim(a[i]); if (a[i] == "") continue; out = out (out == "" ? "" : ",") "\"" esc(a[i]) "\""; areas[++na] = a[i] }
  return out
}
function bad(msg) { print "error\t" msg; failed = 1; exit }
BEGIN { status = "proposed"; units = ""; held = ""; nu = 0 }
/^[ \t]*(#|$)/ { next }
/^status:/ { v = trim(substr($0, 8)); if (v != "proposed" && v != "started") bad("status is proposed or started, not " v); status = v; next }
/^(unit|hold):/ {
  kind = ($0 ~ /^unit:/) ? "unit" : "hold"
  body = substr($0, kind == "unit" ? 6 : 6)
  np = split(body, part, /\|/)
  nums = numlist(part[1])
  if (nums == "" || nums == "!") bad("a " kind " line starts with the issue numbers: " $0)
  ni = split(nums, ns, ",")
  for (i = 1; i <= ni; i++) { if (ns[i] in seenissue) bad("issue " ns[i] " appears twice"); seenissue[ns[i]] = 1 }
  why = ""; files = ""; pr = ""; after = ""; na = 0; delete areas
  for (p = 2; p <= np; p++) {
    s = trim(part[p]); k = s; sub(/:.*/, "", k); v = trim(substr(s, length(k) + 2)); k = tolower(trim(k))
    if (k == "why") why = v
    else if (k == "files") files = arealist(v)
    else if (k == "pr") { if (v !~ /^#?[0-9]+$/) bad("pr is a number: " s); pr = v; sub(/#/, "", pr) }
    else if (k == "after") { after = numlist(v); if (after == "!") bad("after names issue numbers: " s) }
    else bad("unknown field " k " in: " $0)
  }
  for (i = 1; i <= na; i++) { if (areas[i] in seenarea) bad("file " areas[i] " is in two lines; a round keeps its units apart"); seenarea[areas[i]] = 1 }
  if (kind == "unit") {
    j = "{\"issues\":[" nums "]" (why != "" ? ",\"whyTogether\":\"" esc(why) "\"" : "") ",\"areas\":[" files "]" (pr != "" ? ",\"pr\":" pr : "") "}"
    units = units (units == "" ? "" : ",") j; nu++
    line = "- "; for (i = 1; i <= ni; i++) line = line (i > 1 ? ", " : "") "#" ns[i]
    if (why != "") line = line ": " why
    if (pr != "") line = line " (pull request #" pr ")"
    lines = lines line "\n"
    issues = issues (issues == "" ? "" : ",") nums
    if (pr == "") open = open (open == "" ? "" : ",") nums
  } else {
    j = "{\"issues\":[" nums "],\"waitsOn\":[" after "],\"areas\":[" files "]}"
    held = held (held == "" ? "" : ",") j
    line = "- Waiting: "; for (i = 1; i <= ni; i++) line = line (i > 1 ? ", " : "") "#" ns[i]
    lines = lines line "\n"
  }
  next
}
{ bad("a line this script does not know: " $0) }
END {
  if (failed) exit
  if (nu == 0) { print "error\tthe round has no unit line"; exit }
  print "json\t{\"status\":\"" status "\",\"units\":[" units "],\"held\":[" held "]}"
  print "open\t" open
  print "status\t" status
  print "count\t" nu
  printf "lines\t%s", lines
}' "$file") || exit 1

err=$(printf '%s\n' "$out" | sed -n 's/^error\t//p' | head -n 1)
if [ -n "$err" ]; then echo "The round was not published: $err." >&2; exit 1; fi
json=$(printf '%s\n' "$out" | sed -n 's/^json\t//p')
status=$(printf '%s\n' "$out" | sed -n 's/^status\t//p')
count=$(printf '%s\n' "$out" | sed -n 's/^count\t//p')
open=$(printf '%s\n' "$out" | sed -n 's/^open\t//p')
list=$(printf '%s\n' "$out" | sed -n '/^lines\t/,$p' | sed '1s/^lines\t//')

agents="$count agent"; [ "$count" = 1 ] || agents="${agents}s"
if [ "$status" = started ]; then head="Round started: $agents at work."; else head="Proposed next round: $agents."; fi
body_file="${TMPDIR:-/tmp}/publish-round.$$.md"
{
  printf '%s\n\n%s\n\n' "$head" "$list"
  printf '<!-- sipnship-proposal %s -->\n' "$json"
} > "$body_file"

if [ "$dry" = yes ]; then
  cat "$body_file"
  [ "$status" = started ] && [ "$labels" = yes ] && [ -n "$open" ] && echo "(would set In progress: $open)"
  rm -f "$body_file"
  exit 0
fi

if [ -z "$issue" ]; then
  issue=$(gh api "repos/{owner}/{repo}/issues?labels=drive&state=open&per_page=1" --jq '.[0].number // empty' 2>/dev/null)
fi
if [ -z "$issue" ]; then
  rm -f "$body_file"
  echo "The round was not published: no open issue is labeled drive. Pass --issue N to name the drive issue." >&2
  exit 1
fi

if ! gh api -X POST "repos/{owner}/{repo}/issues/$issue/comments" -F "body=@$body_file" >/dev/null 2>"$body_file.err"; then
  echo "The round was not published: GitHub refused the comment on #$issue ($(head -n 1 "$body_file.err"))." >&2
  rm -f "$body_file" "$body_file.err"
  exit 1
fi
rm -f "$body_file" "$body_file.err"
echo "Published the round on #$issue: $agents, $status."

# Dispatching is what sets In progress: the label, over REST, for each unit still without a pull request.
if [ "$status" = started ] && [ "$labels" = yes ] && [ -n "$open" ]; then
  for n in $(printf '%s' "$open" | tr ',' ' '); do
    have=$(gh api "repos/{owner}/{repo}/issues/$n/labels" --jq '.[].name' 2>/dev/null)
    form="state:in-progress"
    printf '%s\n' "$have" | grep -q '^state: ' && form="state: in-progress"
    printf '%s\n' "$have" | grep -qxF "$form" && { echo "#$n: already In progress."; continue; }
    printf '%s\n' "$have" | grep -E '^state: ?' | while IFS= read -r l; do
      enc=$(printf '%s' "$l" | sed 's/:/%3A/g;s/ /%20/g')
      gh api -X DELETE "repos/{owner}/{repo}/issues/$n/labels/$enc" >/dev/null 2>&1
    done
    if gh api -X POST "repos/{owner}/{repo}/issues/$n/labels" -f "labels[]=$form" >/dev/null 2>&1; then echo "#$n: set to In progress."; else echo "#$n: could not set In progress; set it with scripts/state.sh."; fi
  done
fi

#!/bin/sh
# Publish a round to the dashboard's Work tab: one comment on the open issue
# labeled `drive`, carrying the round as the marker the service reads
# (`<!-- sipnship-proposal {...} -->`). The drive, or a coordinator acting as
# it, runs this when it proposes a round and again when it dispatches it. A
# later comment replaces the earlier one on the tab.
#
# Usage, from the project root:
#   sh "$CLAUDE_PLUGIN_ROOT/scripts/drive/publish-round.sh" [--issue N] [--areas FILE] [--dry-run] [--no-labels] ROUND_FILE
#
# ROUND_FILE is plain lines. Blank lines and lines starting with # are ignored.
#   status: proposed          proposed (the default) waits for a go-ahead and
#                             draws as "Proposed next round"; started means the
#                             round was dispatched and draws as Working cards
#   unit: 12 14 | why: both change the watering schedule | areas: watering | pr: 531
#                             one agent's work: its issues, then its fields;
#                             "why" is for a bundle, "areas" (required) are
#                             the areas it changes, by name from the project's
#                             list or by a path inside one ("files" is the
#                             older word for it), "pr" is the pull request once
#                             the agent opens it (the unit then belongs to the
#                             Queue and leaves Work)
#   hold: 16 | after: 12 14 | why: Waits on your read of the bed map design | pr: 560 | areas: beds
#                             work held back: "after" names the issues it waits
#                             on (a running unit's, a held design's, an issue
#                             whose question waits); "why" is the reason in the
#                             builder's words, shown on the Work tab, and a
#                             decline of what the plan proposed is a hold with
#                             a why; "pr" is a pull request the reason names.
#                             The tab drops the reason once what it names has
#                             landed or closed. A round may be holds only: one
#                             that starts nothing still says why
#   looked: 2026-11-06T19:00:00-08:00
#                             when the drive looked (default: now); a proposed
#                             round the same as the one on the drive issue but
#                             for this is updated in place, so the tab shows
#                             the last look apart from when the round changed
#   apart: 12 18 | why: 18 only renames the screen's title | areas: watering
#                             two issues in one area that run apart anyway, and
#                             why; the Work tab shows the reason
#   waits: the usage saving to end, about 1 AM Thursday
#                             what the whole proposed round waits for, in
#                             plain words; the Work tab says it waits, and on
#                             what, instead of saying it starts on its own
# No two units may share an issue, and no two may share an area of the list
# the project keeps (.claude/areas.txt, or --areas FILE; scripts/drive/
# areas-lib.sh gives its form) unless an apart line says why: the script says
# to bundle them or hold one behind the other, and posts nothing. A unit in an
# area that a running unit owns (the latest started round on the drive issue,
# with an issue still In progress) is refused the same way: new work there
# goes to that unit, or waits behind it. A round published by hand is held to
# this as much as the drive's own. With status started, each unit's issues that have no pull request
# are set to In progress (the state label, over REST; the nightly board sync
# sets the board's field), so a dispatched unit never shows as Ready.
# --issue names the drive issue when more than one is open; --dry-run prints
# the comment and changes nothing; --no-labels leaves the labels alone.
# Everything here is REST. Needs gh signed in.
here=$(dirname "$0")
. "$here/../../hooks/scripts/lib.sh"
. "$here/round-lib.sh"
. "$here/areas-lib.sh"

issue=""; dry=no; labels=yes; file=""; areas_file=.claude/areas.txt
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) shift; issue=$1 ;;
    --dry-run) dry=yes ;;
    --no-labels) labels=no ;;
    --areas) shift; areas_file=$1 ;;
    -*) echo "publish-round: unknown option $1" >&2; exit 2 ;;
    *) file=$1 ;;
  esac
  shift
done
[ -n "$file" ] && [ -f "$file" ] || { echo "Usage: publish-round.sh [--issue N] [--areas FILE] [--dry-run] [--no-labels] ROUND_FILE" >&2; exit 2; }

# The areas each line names, as names from the project's list, or the first thing wrong.
list=""; [ -f "$areas_file" ] && list=$(cat "$areas_file")
round=$(round_areas "$list" "$(cat "$file")" "$areas_file")
err=$(printf '%s\n' "$round" | sed -n 's/^error\t//p' | head -n 1)
if [ -n "$err" ]; then echo "The round was not published: $err." >&2; exit 1; fi

# The drive issue, and the units of the round now running, so new work in their areas goes to them.
count=""
if [ -z "$issue" ]; then
  found=$(gh api "repos/{owner}/{repo}/issues?labels=drive&state=open&per_page=1" --jq '.[0] // empty | [(.number | tostring), (.comments | tostring)] | @tsv' 2>/dev/null | tr -d '\r' | head -n 1)
  issue=$(printf '%s' "$found" | cut -f1); count=$(printf '%s' "$found" | cut -f2)
fi
running=""
if [ -n "$issue" ]; then
  [ -n "$count" ] || count=$(gh api "repos/{owner}/{repo}/issues/$issue" --jq '.comments' 2>/dev/null | tr -d '\r')
  rows=""
  for page in $(comment_pages "$count"); do
    rows="${rows}$(gh api "repos/{owner}/{repo}/issues/$issue/comments?per_page=100&page=$page" --jq '.[] | "\(.id)\t" + (.body | gsub("[\r\n]+"; " "))' 2>/dev/null)
"
  done
  # Each comment's id, a tab, then its body on one line; the bodies alone for the running round.
  bodies=$(printf '%s' "$rows" | sed 's/^[0-9][0-9]*	//')
  if printf '%s' "$bodies" | grep -qF 'sipnship-proposal {"status":"started"'; then
    inprog=$(gh api "repos/{owner}/{repo}/issues?state=open&labels=state:in-progress&per_page=100" --jq '.[].number' 2>/dev/null)
    inprog="$inprog
$(gh api "repos/{owner}/{repo}/issues?state=open&labels=state:%20in-progress&per_page=100" --jq '.[].number' 2>/dev/null)"
    running=$(running_units "$bodies" "$inprog")
  fi
fi
err=$(area_problem "$round" "$running")
if [ -n "$err" ]; then echo "The round was not published: $err." >&2; exit 1; fi

# The round as JSON and as a plain comment, or the first thing wrong with it.
out=$(printf '%s\n' "$round" | awk -v now="$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
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
BEGIN { status = "proposed"; units = ""; held = ""; apart = ""; waits = ""; looked = ""; nu = 0; nh = 0 }
/^[ \t]*(#|$)/ { next }
/^looked:/ {
  looked = trim(substr($0, 8))
  if (looked !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9](:[0-9][0-9])?(\.[0-9]+)?(Z|[+-][0-9][0-9]:?[0-9][0-9])$/) bad("looked is a time with its zone, as 2026-11-06T19:00:00-08:00: " $0)
  next
}
/^waits:/ { waits = substr(trim(substr($0, 7)), 1, 200); next }
/^status:/ { v = trim(substr($0, 8)); if (v != "proposed" && v != "started") bad("status is proposed or started, not " v); status = v; next }
/^(unit|hold|apart):/ {
  kind = $0; sub(/:.*/, "", kind)
  body = substr($0, length(kind) + 2)
  np = split(body, part, /\|/)
  nums = numlist(part[1])
  if (nums == "" || nums == "!") bad("a " kind " line starts with the issue numbers: " $0)
  ni = split(nums, ns, ",")
  if (kind != "apart") for (i = 1; i <= ni; i++) { if (ns[i] in seenissue) bad("issue " ns[i] " appears twice"); seenissue[ns[i]] = 1 }
  why = ""; files = ""; pr = ""; after = ""; na = 0; delete areas
  for (p = 2; p <= np; p++) {
    s = trim(part[p]); k = s; sub(/:.*/, "", k); v = trim(substr(s, length(k) + 2)); k = tolower(trim(k))
    if (k == "why") why = v
    else if (k == "areas") files = arealist(v)
    else if (k == "pr") { if (v !~ /^#?[0-9]+$/) bad("pr is a number: " s); pr = v; sub(/#/, "", pr) }
    else if (k == "after") { after = numlist(v); if (after == "!") bad("after names issue numbers: " s) }
    else bad("unknown field " k " in: " $0)
  }
  if (kind == "apart") {
    if (ni < 2) bad("an apart line names the two issues kept apart: " $0)
    apart = apart (apart == "" ? "" : ",") "{\"issues\":[" nums "],\"why\":\"" esc(why) "\",\"areas\":[" files "]}"
    line = "- Left apart: "; for (i = 1; i <= ni; i++) line = line (i > 1 ? ", " : "") "#" ns[i]
    lines = lines line ": " why "\n"
  } else if (kind == "unit") {
    j = "{\"issues\":[" nums "]" (why != "" ? ",\"whyTogether\":\"" esc(why) "\"" : "") ",\"areas\":[" files "]" (pr != "" ? ",\"pr\":" pr : "") "}"
    units = units (units == "" ? "" : ",") j; nu++
    line = "- "; for (i = 1; i <= ni; i++) line = line (i > 1 ? ", " : "") "#" ns[i]
    if (why != "") line = line ": " why
    if (pr != "") line = line " (pull request #" pr ")"
    lines = lines line "\n"
    issues = issues (issues == "" ? "" : ",") nums
    if (pr == "") open = open (open == "" ? "" : ",") nums
  } else {
    why = substr(why, 1, 200)
    j = "{\"issues\":[" nums "],\"waitsOn\":[" after "],\"areas\":[" files "]" (why != "" ? ",\"why\":\"" esc(why) "\"" : "") (pr != "" ? ",\"pr\":" pr : "") "}"
    held = held (held == "" ? "" : ",") j; nh++
    line = "- Waiting: "; for (i = 1; i <= ni; i++) line = line (i > 1 ? ", " : "") "#" ns[i]
    if (why != "") line = line ": " why
    if (pr != "") line = line " (pull request #" pr ")"
    lines = lines line "\n"
  }
  next
}
{ bad("a line this script does not know: " $0) }
END {
  if (failed) exit
  # A proposed round may start nothing and still say why: holds only. A started round has a unit.
  if (nu == 0 && (nh == 0 || status == "started")) { print "error\tthe round has no unit line"; exit }
  if (waits != "") lines = lines "- Waits on: " waits "\n"
  if (looked == "") looked = now
  print "json\t{\"status\":\"" status "\",\"units\":[" units "]" (status == "proposed" ? ",\"looked\":\"" esc(looked) "\"" : "") ",\"held\":[" held "]" (apart != "" ? ",\"apart\":[" apart "]" : "") (waits != "" ? ",\"waits\":\"" esc(waits) "\"" : "") "}"
  print "open\t" open
  print "status\t" status
  print "count\t" nu
  print "held\t" nh
  printf "lines\t%s", lines
}') || exit 1

err=$(printf '%s\n' "$out" | sed -n 's/^error\t//p' | head -n 1)
if [ -n "$err" ]; then echo "The round was not published: $err." >&2; exit 1; fi
json=$(printf '%s\n' "$out" | sed -n 's/^json\t//p')
status=$(printf '%s\n' "$out" | sed -n 's/^status\t//p')
count=$(printf '%s\n' "$out" | sed -n 's/^count\t//p')
open=$(printf '%s\n' "$out" | sed -n 's/^open\t//p')
list=$(printf '%s\n' "$out" | sed -n '/^lines\t/,$p' | sed '1s/^lines\t//')

nheld=$(printf '%s\n' "$out" | sed -n 's/^held\t//p')
agents="$count agent"; [ "$count" = 1 ] || agents="${agents}s"
if [ "$status" = started ]; then head="Round started: $agents at work."
elif [ "$count" = 0 ]; then head="Proposed next round: nothing starts yet, $nheld held back."
else head="Proposed next round: $agents."; fi
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
  rm -f "$body_file"
  echo "The round was not published: no open issue is labeled drive. Pass --issue N to name the drive issue." >&2
  exit 1
fi

# The same proposed round as the latest on the drive issue but for when the drive looked: that comment is
# updated in place, so the tab keeps when the round last changed and shows when the drive last looked.
same=""
if [ "$status" = proposed ] && [ -n "$rows" ]; then
  bare() { printf '%s' "$1" | sed 's/.*sipnship-proposal //; s/ -->.*//; s/,"looked":"[^"]*"//'; }
  last=$(printf '%s\n' "$rows" | grep -F 'sipnship-proposal {' | grep -vF 'sipnship-proposal {"status":"started"' | tail -n 1)
  [ -n "$last" ] && [ "$(bare "$last")" = "$(bare "<!-- sipnship-proposal $json -->")" ] && same=$(printf '%s' "$last" | cut -f1)
  case "$same" in *[!0-9]*) same="" ;; esac
fi
if [ -n "$same" ]; then
  if ! gh api -X PATCH "repos/{owner}/{repo}/issues/comments/$same" -F "body=@$body_file" >/dev/null 2>"$body_file.err"; then
    echo "The round was not updated: GitHub refused the edit on #$issue ($(head -n 1 "$body_file.err"))." >&2
    rm -f "$body_file" "$body_file.err"
    exit 1
  fi
  rm -f "$body_file" "$body_file.err"
  echo "Updated the round on #$issue: the same round, looked at again."
  exit 0
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

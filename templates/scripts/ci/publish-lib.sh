#!/bin/sh
# Pure helpers for publishing the merge queue's state (spec 001): the three
# sentences a builder reads, the JSON an agent reads, and the issue body
# that holds both. Text in, text out; no gh here. publish-state.sh gathers
# the facts and calls these.
#
# Inputs, one record per line, tab separated:
#   OPEN      number, title, state, say      (state: waiting green red
#             draft conflicts-with-main clash held)
#   BATCH     first line: number (empty before its pull request opens),
#             members (space separated, in order), anchor, done, total,
#             minutes left, stage (cut building testing landed), run id,
#             runner; then one line per member "pull\tN\tTITLE\tSTATE"
#             (planned merged) and per member dropped "dropped\tN\tTITLE\tWHY".
#             Empty when no batch is under way. batch_from_state builds it
#             from the queue's batch.state file.
#   BUILDING  "merged total current member..." while a batch is built on
#             the queue's machine; empty otherwise
#   CLASHES   leftOut, with, with's title, files (space separated), why
#             (the queue's own words), told (yes/no)
#   LANDED    number, title, how (serial/batch), at (ISO)
#   RUNNERS   online, busy, queued, longest wait in minutes; empty if unread
#   ATTENTION number, what, why, first error line
#   MAIN      sha, state (green red pending unknown)
#   DEPLOY    one line from deploy-gate, or empty
#   MODE      idle draining serial batch paused

# json_str TEXT: TEXT as a JSON string, quotes included.
json_str() {
  printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }')"
}

# json_num TEXT: a number, or null when TEXT is not one.
json_num() { case "$1" in ''|*[!0-9]*) printf 'null' ;; *) printf '%s' "$1" ;; esac; }

# json_list TEXT: the whitespace-separated numbers of TEXT as a JSON array.
json_list() {
  jl_out=""
  for jl_n in $1; do jl_out="$jl_out${jl_out:+,}$(json_num "$jl_n")"; done
  printf '[%s]' "$jl_out"
}

# plural N ONE MANY
plural() { if [ "$1" = 1 ]; then printf '%s %s' "$1" "$2"; else printf '%s %s' "$1" "$3"; fi; }

# numbers_said LIST: "#12, #13 and #14"
numbers_said() {
  ns_n=$(printf '%s\n' $1 | sed '/^$/d' | wc -l | tr -d ' ')
  printf '%s\n' $1 | sed '/^$/d' | awk -v n="$ns_n" '{ if (NR == 1) printf "#%s", $1; else if (NR == n) printf " and #%s", $1; else printf ", #%s", $1 }'
}

# batch_head BATCH: its first line, the one the fields above describe.
batch_head() { printf '%s\n' "$1" | sed -n 1p; }

# batch_from_state STATE DONE TOTAL MINUTES RUNNER: the BATCH record from
# the queue's batch.state lines ("stage\tS", "pr\tN", "run\tID",
# "member\tN\tTITLE\tSTATE", "dropped\tN\tTITLE\tWHY"), with the run's
# progress as publish-state.sh read it. Nothing when STATE has no member.
batch_from_state() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v done="$2" -v total="$3" -v min="$4" -v runner="$5" '
    $1 == "stage" { stage = $2 } $1 == "pr" { pr = $2 } $1 == "run" { run = $2 }
    $1 == "member" { if (!($2 in seen)) { seen[$2] = 1; m[++n] = $2; t[$2] = $3; st[$2] = ($4 == "" ? "planned" : $4) } else if ($4 != "") st[$2] = $4 }
    $1 == "dropped" { d[++k] = $2 "\t" $3 "\t" $4; gone[$2] = 1 }
    END {
      list = ""; anchor = ""
      for (i = 1; i <= n; i++) if (!(m[i] in gone)) { list = list (list == "" ? "" : " ") m[i]; if (anchor == "") anchor = m[i] }
      if (list == "") exit
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", pr, list, anchor, done, total, min, stage, run, runner
      for (i = 1; i <= n; i++) if (!(m[i] in gone)) printf "pull\t%s\t%s\t%s\n", m[i], t[m[i]], st[m[i]]
      for (i = 1; i <= k; i++) printf "dropped\t%s\n", d[i]
    }'
}

# files_said FILES: "dates.ts", or "dates.ts and 2 other files", by base name.
files_said() {
  fs_n=$(printf '%s\n' $1 | sed '/^$/d' | wc -l | tr -d ' ')
  fs_first=$(printf '%s\n' $1 | sed '/^$/d' | head -n 1 | sed 's#.*/##')
  if [ "$fs_n" = 0 ]; then printf 'files the batch changes'
  elif [ "$fs_n" = 1 ]; then printf '%s' "$fs_first"
  else printf '%s and %s' "$fs_first" "$(plural $((fs_n - 1)) 'other file' 'other files')"; fi
}

# publish_say OPEN BATCH BUILDING CLASHES ATTENTION RUNNERS DEPLOY MODE PAUSED_UNTIL
# Three sentences, one per line: what the queue is doing now; what is
# waiting and why; what needs a person. Plain words, never a field name.
publish_say() {
  ps_open=$1; ps_batch=$2; ps_building=$3; ps_clashes=$4; ps_att=$5; ps_runners=$6; ps_deploy=$7; ps_mode=$8; ps_until=$9
  # 1. Doing now.
  ps_busy=""; ps_online=""
  if [ -n "$ps_runners" ]; then
    ps_online=$(printf '%s' "$ps_runners" | cut -f1); ps_b=$(printf '%s' "$ps_runners" | cut -f2)
    if [ "${ps_online:-0}" -gt 0 ] 2>/dev/null; then ps_busy="$ps_b of $ps_online runners busy"; fi
  fi
  ps_bh=$(batch_head "$ps_batch")
  pb_num=$(printf '%s' "$ps_bh" | cut -f1); pb_stage=$(printf '%s' "$ps_bh" | cut -f7)
  if [ -n "$ps_bh" ] && [ -z "$pb_num" ] && [ -z "$ps_building" ]; then
    pb_members=$(printf '%s' "$ps_bh" | cut -f2); pb_total=$(printf '%s\n' $pb_members | sed '/^$/d' | wc -l | tr -d ' ')
    s1="Building a batch of $(plural "$pb_total" 'pull request' 'pull requests') on the queue's own machine ($(numbers_said "$pb_members"))."
  elif [ -n "$ps_bh" ] && [ -n "$pb_num" ]; then
    pb_members=$(printf '%s' "$ps_bh" | cut -f2); pb_total=$(printf '%s\n' $pb_members | sed '/^$/d' | wc -l | tr -d ' '); pb_min=$(printf '%s' "$ps_bh" | cut -f6)
    pb_d=$(printf '%s' "$ps_bh" | cut -f4); pb_t=$(printf '%s' "$ps_bh" | cut -f5); pb_runner=$(printf '%s' "$ps_bh" | cut -f9)
    if [ "$pb_stage" = landed ]; then
      s1="A batch of $(plural "$pb_total" 'pull request' 'pull requests') ($(numbers_said "$pb_members")) landed on main."
    else
      s1="Testing a batch of $(plural "$pb_total" 'pull request' 'pull requests') together ($(numbers_said "$pb_members"))"
      pb_more=""
      if [ "${pb_t:-0}" -gt 0 ] 2>/dev/null; then pb_more="$((pb_d * 100 / pb_t))% through the checks"; fi
      [ -n "$pb_min" ] && pb_more="${pb_more:+$pb_more, }about $(plural "$pb_min" minute minutes) left"
      [ -n "$pb_runner" ] && pb_more="${pb_more:+$pb_more, }on $pb_runner"
      [ -n "$pb_more" ] && s1="$s1; $pb_more"
      [ -n "$ps_busy" ] && s1="$s1, $ps_busy"
      s1="$s1."
    fi
  elif [ -n "$ps_building" ]; then
    set -- $ps_building
    s1="Building a batch of $(plural "$2" 'pull request' 'pull requests') on the queue's own machine: $1 merged, checking #$3."
  elif [ "$ps_mode" = paused ]; then
    s1="The scheduled queue is paused${ps_until:+ until $ps_until}; a drain run by hand still runs."
  elif [ "$ps_mode" = serial ]; then
    s1="Merging one pull request on its own."
  elif [ "$ps_mode" = draining ]; then
    s1="The queue is running, looking for green pull requests to merge."
  else
    s1="The queue is idle; it runs every two hours, and after an agent's work."
  fi
  # 2. Waiting and why.
  cnt() { printf '%s\n' "$ps_open" | awk -F'\t' -v s="$1" '$3 == s' | grep -c . || true; }
  nums() { printf '%s\n' "$ps_open" | awk -F'\t' -v s="$1" '$3 == s { print $1 }' | tr '\n' ' '; }
  g=$(cnt green); w=$(cnt waiting); r=$(cnt red); h=$(cnt held); c=$(cnt conflicts-with-main); d=$(cnt draft)
  parts=""
  [ "$g" -gt 0 ] && parts="$parts${parts:+; }$(plural "$g" 'is green' 'are green') and waiting to merge ($(numbers_said "$(nums green)"))"
  [ "$w" -gt 0 ] && parts="$parts${parts:+; }$(plural "$w" 'is' 'are') still running CI"
  [ "$r" -gt 0 ] && parts="$parts${parts:+; }$(plural "$r" 'is red' 'are red') ($(numbers_said "$(nums red)"))"
  [ "$c" -gt 0 ] && parts="$parts${parts:+; }$(plural "$c" 'conflicts' 'conflict') with main ($(numbers_said "$(nums conflicts-with-main)"))"
  [ "$h" -gt 0 ] && parts="$parts${parts:+; }$(plural "$h" 'is held' 'are held') on purpose ($(numbers_said "$(nums held)"))"
  [ "$d" -gt 0 ] && parts="$parts${parts:+; }$(plural "$d" 'is a draft' 'are drafts')"
  total=$(printf '%s\n' "$ps_open" | grep -c . || true)
  if [ "$total" -eq 0 ]; then s2="Nothing is waiting."; else s2="$(plural "$total" 'pull request is open' 'pull requests are open'): $parts."; fi
  if [ -n "$ps_clashes" ]; then
    s2="$s2 $(printf '%s\n' "$ps_clashes" | sed '/^$/d' | while IFS= read -r pc_l; do
      pc_a=$(printf '%s' "$pc_l" | cut -f1); pc_w=$(printf '%s' "$pc_l" | cut -f2); pc_t=$(printf '%s' "$pc_l" | cut -f3); pc_f=$(printf '%s' "$pc_l" | cut -f4); pc_told=$(printf '%s' "$pc_l" | cut -f6)
      if [ "$pc_w" = main ]; then pc_other=main; elif [ -n "$pc_t" ]; then pc_other="\"$pc_t\" (#$pc_w)"; else pc_other="#$pc_w"; fi
      printf '#%s was left out: it changes %s, which %s changes too%s.\n' "$pc_a" "$(files_said "$pc_f")" "$pc_other" "$( [ "$pc_told" = yes ] && printf ', and its owner has been told')"
    done | paste -sd' ' -)"
  fi
  # 3. Needs a person.
  s3=""
  if [ -n "$ps_att" ]; then
    s3=$(printf '%s\n' "$ps_att" | awk -F'\t' '{ printf "#%s %s: %s.", $1, $2, ($4 != "" ? $4 : $3) }' | paste -sd' ' -)
    s3="Needs you: $s3"
  fi
  if [ -n "$ps_runners" ] && [ "${ps_online:-0}" = 0 ] 2>/dev/null; then s3="${s3:+$s3 }No runner is online, so nothing can be tested; start one."; fi
  case "$ps_deploy" in deploy:\ due*) s3="${s3:+$s3 }A deploy is due and will start with the next landing." ;; esac
  [ -n "$s3" ] || s3="Nothing needs you."
  printf '%s\n%s\n%s\n' "$s1" "$s2" "$s3"
}

# publish_json OPEN BATCH BUILDING CLASHES LANDED RUNNERS ATTENTION MAIN DEPLOY MODE PAUSED_UNTIL CHECKING SAY NOW
# The state as one JSON object (version 1). SAY is publish_say's three
# lines; NOW the ISO time of the write.
publish_json() {
  pj_open=$1; pj_batch=$2; pj_building=$3; pj_clashes=$4; pj_landed=$5; pj_runners=$6; pj_att=$7; pj_main=$8; pj_deploy=$9
  shift 9; pj_mode=$1; pj_until=$2; pj_checking=$3; pj_say=$4; pj_now=$5
  printf '{"version":1,"updatedAt":%s,"mode":%s,"pausedUntil":%s,' "$(json_str "$pj_now")" "$(json_str "$pj_mode")" "$( [ -n "$pj_until" ] && json_str "$pj_until" || printf null)"
  printf '"say":{"doing":%s,"waiting":%s,"needs":%s},' "$(json_str "$(printf '%s\n' "$pj_say" | sed -n 1p)")" "$(json_str "$(printf '%s\n' "$pj_say" | sed -n 2p)")" "$(json_str "$(printf '%s\n' "$pj_say" | sed -n 3p)")"
  printf '"main":{"sha":%s,"state":%s},' "$(json_str "$(printf '%s' "$pj_main" | cut -f1)")" "$(json_str "$(printf '%s' "$pj_main" | cut -f2)")"
  printf '"open":['; first=yes
  printf '%s\n' "$pj_open" | sed '/^$/d' | while IFS="$(printf '\t')" read -r n t s say; do
    printf '%s{"number":%s,"title":%s,"state":%s,"say":%s}' "$( [ -f /dev/null ] && printf '' )" "$(json_num "$n")" "$(json_str "$t")" "$(json_str "$s")" "$(json_str "$say")"
    printf '\001'
  done | sed 's/\x01}/}/g; s/\x01{/,{/g; s/\x01$//' | tr -d '\001'
  printf '],'
  printf '"checking":%s,' "$(json_list "$pj_checking")"
  if [ -n "$pj_building" ]; then set -- $pj_building; m=$1; t=$2; c=$3; shift 3; printf '"building":{"merged":%s,"total":%s,"current":%s,"members":%s},' "$(json_num "$m")" "$(json_num "$t")" "$(json_num "$c")" "$(json_list "$*")"; else printf '"building":null,'; fi
  pj_bh=$(batch_head "$pj_batch")
  if [ -n "$pj_bh" ]; then
    pj_f() { printf '%s' "$pj_bh" | cut -f"$1"; }
    pj_opt() { if [ -n "$1" ]; then json_str "$1"; else printf null; fi; }
    pj_pulls=$(printf '%s\n' "$pj_batch" | awk -F'\t' '$1 == "pull"' | while IFS= read -r l; do printf '{"number":%s,"title":%s,"state":%s},' "$(json_num "$(printf '%s' "$l" | cut -f2)")" "$(json_str "$(printf '%s' "$l" | cut -f3)")" "$(json_str "$(printf '%s' "$l" | cut -f4)")"; done | sed 's/,$//')
    pj_drop=$(printf '%s\n' "$pj_batch" | awk -F'\t' '$1 == "dropped"' | while IFS= read -r l; do printf '{"number":%s,"title":%s,"why":%s},' "$(json_num "$(printf '%s' "$l" | cut -f2)")" "$(json_str "$(printf '%s' "$l" | cut -f3)")" "$(json_str "$(printf '%s' "$l" | cut -f4)")"; done | sed 's/,$//')
    printf '"batch":{"number":%s,"stage":%s,"members":%s,"pulls":[%s],"anchor":%s,"run":%s,"runner":%s,"done":%s,"total":%s,"minutesLeft":%s,"dropped":[%s]},' "$(json_num "$(pj_f 1)")" "$(pj_opt "$(pj_f 7)")" "$(json_list "$(pj_f 2)")" "$pj_pulls" "$(json_num "$(pj_f 3)")" "$(json_num "$(pj_f 8)")" "$(pj_opt "$(pj_f 9)")" "$(json_num "$(pj_f 4)")" "$(json_num "$(pj_f 5)")" "$(json_num "$(pj_f 6)")" "$pj_drop"
  else printf '"batch":null,'; fi
  printf '"clashes":[%s],' "$(printf '%s\n' "$pj_clashes" | sed '/^$/d' | while IFS= read -r l; do
    a=$(printf '%s' "$l" | cut -f1); b=$(printf '%s' "$l" | cut -f2); bt=$(printf '%s' "$l" | cut -f3); f=$(printf '%s' "$l" | cut -f4); why=$(printf '%s' "$l" | cut -f5); told=$(printf '%s' "$l" | cut -f6)
    fn=$(printf '%s\n' $f | sed '/^$/d' | wc -l | tr -d ' ')
    printf '{"leftOut":%s,"with":%s,"withTitle":%s,"files":[%s],"file":%s,"fileCount":%s,"why":%s,"told":%s},' "$(json_num "$a")" "$( [ "$b" = main ] && json_str main || json_num "$b")" "$( [ -n "$bt" ] && json_str "$bt" || printf null)" "$(for x in $f; do json_str "$x"; printf ','; done | sed 's/,$//')" "$( [ "$fn" -gt 0 ] && json_str "$(printf '%s\n' $f | head -n 1)" || printf null)" "$fn" "$( [ -n "$why" ] && json_str "$why" || printf null)" "$( [ "$told" = yes ] && printf true || printf false)"; done | sed 's/,$//')"
  printf '"landed":[%s],' "$(printf '%s\n' "$pj_landed" | sed '/^$/d' | while IFS="$(printf '\t')" read -r n t how at; do printf '{"number":%s,"title":%s,"how":%s,"at":%s},' "$(json_num "$n")" "$(json_str "$t")" "$(json_str "$how")" "$(json_str "$at")"; done | sed 's/,$//')"
  if [ -n "$pj_runners" ]; then printf '"runners":{"online":%s,"busy":%s,"queued":%s,"longestWaitMinutes":%s},' "$(json_num "$(printf '%s' "$pj_runners" | cut -f1)")" "$(json_num "$(printf '%s' "$pj_runners" | cut -f2)")" "$(json_num "$(printf '%s' "$pj_runners" | cut -f3)")" "$(json_num "$(printf '%s' "$pj_runners" | cut -f4)")"; else printf '"runners":null,'; fi
  printf '"needsAttention":[%s],' "$(printf '%s\n' "$pj_att" | sed '/^$/d' | while IFS="$(printf '\t')" read -r n what why line; do printf '{"number":%s,"what":%s,"why":%s,"line":%s},' "$(json_num "$n")" "$(json_str "$what")" "$(json_str "$why")" "$(json_str "$line")"; done | sed 's/,$//')"
  printf '"deploy":%s}\n' "$( [ -n "$pj_deploy" ] && json_str "$pj_deploy" || printf null)"
}

# publish_body SAY OPEN BATCH LANDED JSON FIRST
# The issue body: the sentences, one line per open pull request, the
# batch, the last landed, and the JSON block at the end. FIRST is "yes"
# the first time, which adds the paragraph on what the queue is.
publish_body() {
  pb_say=$1; pb_open=$2; pb_batch=$3; pb_landed=$4; pb_json=$5; pb_first=$6
  if [ "$pb_first" = yes ]; then
    printf '%s\n\n' "This issue is the merge queue's own page. The queue merges green pull requests on its own, several at a time when they do not clash, and tests them together before they reach main; this page says what it is doing, what is waiting and why, and what needs you. It is rewritten in place by the queue; nobody writes here by hand. More: scripts/ci/QUEUE.md."
  fi
  printf '%s\n\n' "$(printf '%s\n' "$pb_say" | paste -sd' ' -)"
  if [ -n "$pb_open" ]; then
    printf '## Open\n\n'
    printf '%s\n' "$pb_open" | sed '/^$/d' | awk -F'\t' '{ printf "- #%s %s: %s\n", $1, $2, $4 }'
    printf '\n'
  fi
  pb_bh=$(batch_head "$pb_batch")
  if [ -n "$pb_bh" ]; then
    pb_bn=$(printf '%s' "$pb_bh" | cut -f1)
    printf '## Batch\n\n'
    if [ -n "$pb_bn" ]; then printf -- '- #%s, %s %s\n' "$pb_bn" "$( [ "$(printf '%s' "$pb_bh" | cut -f7)" = landed ] && printf landed || printf testing)" "$(numbers_said "$(printf '%s' "$pb_bh" | cut -f2)")"
    else printf -- '- Being built, %s\n' "$(numbers_said "$(printf '%s' "$pb_bh" | cut -f2)")"; fi
    printf '%s\n' "$pb_batch" | awk -F'\t' '$1 == "pull" { printf "  - #%s %s (%s)\n", $2, $3, $4 } $1 == "dropped" { printf "  - #%s %s: dropped, %s\n", $2, $3, $4 }'
    printf '\n'
  fi
  if [ -n "$pb_landed" ]; then
    printf '## Landed lately\n\n'
    printf '%s\n' "$pb_landed" | sed '/^$/d' | awk -F'\t' '{ printf "- #%s %s (%s, %s)\n", $1, $2, $3, substr($4, 1, 16) (($4 ~ /Z$/) ? "Z" : "") }'
    printf '\n'
  fi
  printf '<!-- The state as an agent reads it; the sentences above are its say fields. -->\n```json\n%s\n```\n' "$pb_json"
}

# published_json BODY: the JSON block out of an issue body, or nothing.
published_json() {
  printf '%s\n' "$1" | tr -d '\r' | awk '/^```json$/ { on = 1; next } /^```$/ { if (on) exit } on { print }'
}

# --- The service road (QUEUE_PUBLISH_STATE=service): the same state, sent to
# the repository's SipNShip dashboard instead of the issue. Latest only,
# names never contents, nothing read back but the status.

# service_waits_json ROWS SINCE: the queue's waits log (epoch, time, job,
# busy, total, minutes) since SINCE as the wait lines the service reads.
service_waits_json() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v since="$2" '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    NF >= 6 && $1 + 0 >= since {
      if (n >= 200) next
      why = ($5 + 0 == 0) ? "" : ($4 + 0 >= $5 + 0) ? (($5 + 0 == 1) ? "the one runner was busy" : "all " $5 " runners were busy") : ($4 " of " $5 " runners were busy")
      line = sprintf("{\"job\":\"%s\",\"waitedSeconds\":%d", esc($3), ($6 + 0) * 60)
      if (why != "") line = line sprintf(",\"why\":\"%s\"", why)
      out = out (n ? "," : "") line "}"; n++
    }
    END { printf "[%s]", out }'
}

# service_body STATE_JSON WAITS_JSON: spec 001's state, version 1 and
# unchanged, with the wait lines added.
service_body() {
  printf '%s' "$1" | sed 's/}[[:space:]]*$//' | tr -d '\n'
  printf ',"waits":%s}' "${2:-[]}"
}

# service_outcome HTTP_STATUS: ok, not_connected, too_large, rate_limited or
# unreachable (no answer, a timeout, a 5xx, anything else).
service_outcome() {
  case "$1" in
    2[0-9][0-9]) printf ok ;;
    401) printf not_connected ;;
    413) printf too_large ;;
    429) printf rate_limited ;;
    *) printf unreachable ;;
  esac
}

# service_issue_too FAILING_SINCE NOW: yes when sends have failed for an
# hour, so the issue is written as well until a send succeeds.
service_issue_too() {
  case "$1" in ''|0|*[!0-9]*) printf no; return ;; esac
  if [ $(( $2 - $1 )) -ge 3600 ]; then printf yes; else printf no; fi
}

# service_say OUTCOME: the one plain line a failed send says.
service_say() {
  case "$1" in
    not_connected) printf '%s' "This machine is no longer connected to SipNShip, so the merge queue keeps its issue current after an hour. Reconnect it from the dashboard." ;;
    too_large) printf '%s' "The queue's state was too long to send to SipNShip; the next change tries again." ;;
    unreachable) printf '%s' "Could not reach SipNShip with the queue's state; the queue carries on, and writes its issue too if this lasts an hour." ;;
  esac
}

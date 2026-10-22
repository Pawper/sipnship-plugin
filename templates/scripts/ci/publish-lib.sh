#!/bin/sh
# Pure helpers for publishing the merge queue's state (spec 001): the three
# sentences a builder reads, the JSON an agent reads, and the issue body
# that holds both. Text in, text out; no gh here. publish-state.sh gathers
# the facts and calls these.
#
# Inputs, one record per line, tab separated:
#   OPEN      number, title, state, say      (state: waiting green red
#             draft conflicts-with-main clash held)
#   BATCH     number, members (space separated), anchor, done, total,
#             minutes left; empty when no batch pull request is open
#   BUILDING  "merged total current member..." while a batch is built on
#             the queue's machine; empty otherwise
#   CLASHES   leftOut, with, files (space separated), told (yes/no)
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
  if [ -n "$ps_batch" ]; then
    pb_num=$(printf '%s' "$ps_batch" | cut -f1); pb_members=$(printf '%s' "$ps_batch" | cut -f2); pb_total=$(printf '%s\n' $pb_members | sed '/^$/d' | wc -l | tr -d ' '); pb_min=$(printf '%s' "$ps_batch" | cut -f6)
    s1="Testing a batch of $(plural "$pb_total" 'pull request' 'pull requests') together ($(numbers_said "$pb_members"))"
    [ -n "$pb_min" ] && s1="$s1; about $(plural "$pb_min" minute minutes) left"
    [ -n "$ps_busy" ] && s1="$s1, $ps_busy"
    s1="$s1."
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
    s2="$s2 $(printf '%s\n' "$ps_clashes" | awk -F'\t' '{ files = $3; gsub(/ /, ", ", files); told = ($4 == "yes") ? ", and its owner has been told" : ""; printf "#%s was left out: it clashes with #%s in %s%s.", $1, $2, (files == "" ? "files the batch changes" : files), told } END { }' | paste -sd' ' -)"
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
  if [ -n "$pj_batch" ]; then
    printf '"batch":{"number":%s,"members":%s,"anchor":%s,"done":%s,"total":%s,"minutesLeft":%s},' "$(json_num "$(printf '%s' "$pj_batch" | cut -f1)")" "$(json_list "$(printf '%s' "$pj_batch" | cut -f2)")" "$(json_num "$(printf '%s' "$pj_batch" | cut -f3)")" "$(json_num "$(printf '%s' "$pj_batch" | cut -f4)")" "$(json_num "$(printf '%s' "$pj_batch" | cut -f5)")" "$(json_num "$(printf '%s' "$pj_batch" | cut -f6)")"
  else printf '"batch":null,'; fi
  printf '"clashes":[%s],' "$(printf '%s\n' "$pj_clashes" | sed '/^$/d' | while IFS="$(printf '\t')" read -r a b f told; do printf '{"leftOut":%s,"with":%s,"files":[%s],"told":%s},' "$(json_num "$a")" "$(json_num "$b")" "$(for x in $f; do json_str "$x"; printf ','; done | sed 's/,$//')" "$( [ "$told" = yes ] && printf true || printf false)"; done | sed 's/,$//')"
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
  if [ -n "$pb_batch" ]; then
    printf '## Batch\n\n- #%s, testing %s\n\n' "$(printf '%s' "$pb_batch" | cut -f1)" "$(numbers_said "$(printf '%s' "$pb_batch" | cut -f2)")"
  fi
  if [ -n "$pb_landed" ]; then
    printf '## Landed lately\n\n'
    printf '%s\n' "$pb_landed" | sed '/^$/d' | awk -F'\t' '{ printf "- #%s %s (%s, %s)\n", $1, $2, $3, substr($4, 1, 16) }'
    printf '\n'
  fi
  printf '<!-- The state as an agent reads it; the sentences above are its say fields. -->\n```json\n%s\n```\n' "$pb_json"
}

# published_json BODY: the JSON block out of an issue body, or nothing.
published_json() {
  printf '%s\n' "$1" | tr -d '\r' | awk '/^```json$/ { on = 1; next } /^```$/ { if (on) exit } on { print }'
}

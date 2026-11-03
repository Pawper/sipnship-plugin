#!/bin/sh
# Pure rules for the drain's rescue of builds that were placed on a machine
# that went offline. A queued job never moves, so a run whose job waits past
# the builder's wait limit with nowhere to run is cancelled and started
# again, and its place job chooses afresh. Loaded by scripts/ci/batch-lib.sh
# after rules-place.sh; nothing here calls git or gh. Tested with one
# fixture a case in tests/fixtures/rescue/.

# rescue_on ORDER: "yes" when the order (rules-place.sh) has more than one
# place and a wait limit, so a stuck run has somewhere else to go. "My
# machines only", or "as long as it takes", is never rescued.
rescue_on() {
  ro_order=$(places_get "$1" order)
  ro_wait=$(places_get "$1" wait)
  case "$ro_order:$ro_wait" in
    *,*:none|*,*:) echo no ;;
    *,*:*) echo yes ;;
    *) echo no ;;
  esac
}

# rescue_runs ORDER JOBS RUNNERS NOW
# The runs to start again, one line each: "restart RUN PLACE REASON".
# JOBS is one job a line, "run<TAB>attempt<TAB>name<TAB>status<TAB>labels<TAB>created"
# (created in epoch seconds); RUNNERS is "status<TAB>busy<TAB>labels" a runner.
# A run is rescued when:
#   - it was placed: it has a job named "place" (or "place / ..."), finished;
#   - it has not been started three times already (a build no place can
#     take waits, it does not go round);
#   - one of its jobs has been queued longer than the wait limit, and
#       on your machines' labels, no online runner carries them all
#         (REASON "offline": the machine went off after the job was placed);
#       on a hosted place's label, that place is in the order
#         (REASON "stuck": it left the job waiting, as a provider out of
#         credit may; the drain then passes it over for an hour).
# A job merely queued while a runner with its labels is online is left alone:
# the runner will take it.
rescue_runs() {
  { place_providers | sed 's/^/P\t/'; printf '%s\n' "$3" | tr -d '\r' | sed 's/^/R\t/'; printf '%s\n' "$2" | tr -d '\r' | sed 's/^/J\t/'; } \
  | awk -F'\t' -v order="$1" -v now="$4" '
    function tok(k,   n, a, i, v) { v = ""; n = split(order, a, " "); for (i = 1; i <= n; i++) if (index(a[i], k "=") == 1) v = substr(a[i], length(k) + 2); return v }
    function has(list, x,   n, a, i) { n = split(list, a, ","); for (i = 1; i <= n; i++) if (a[i] == x) return 1; return 0 }
    function served(labels,   n, w, i, j, ok) {
      n = split(labels, w, ",")
      for (j = 1; j <= nr; j++) {
        if (rs[j] != "online") continue
        ok = 1; for (i = 1; i <= n; i++) if (w[i] != "" && !has(rl[j], w[i])) ok = 0
        if (ok) return 1
      }
      return 0
    }
    $1 == "P" { for (i = 4; i <= 6; i++) if ($i != "-") hosted[$i] = $2; next }
    $1 == "R" && NF >= 4 { nr++; rs[nr] = $2; rl[nr] = $4; next }
    $1 == "J" && NF >= 7 {
      run = $2
      if (!(run in seen)) { seen[run] = 1; runs[++nruns] = run }
      attempt[run] = $3 + 0
      if (($4 == "place" || index($4, "place / ") == 1) && $5 == "completed") placed[run] = 1
      if ($5 != "queued" || (run in why)) next
      if (limit == "") { limit = tok("wait") }
      if (limit == "" || limit == "none" || (now - $7) / 60 <= limit + 0) next
      if ($6 in hosted) {
        if (has(tok("order"), hosted[$6])) { why[run] = "stuck"; where[run] = hosted[$6] }
      } else if (!served($6)) { why[run] = "offline"; where[run] = "own" }
    }
    END {
      for (i = 1; i <= nruns; i++) {
        r = runs[i]
        if ((r in why) && (r in placed) && attempt[r] < 3) printf "restart %s %s %s\n", r, where[r], why[r]
      }
    }'
}

# rescue_skip REFUSED PLACE NOW: the new value of SIPNSHIP_PLACE_REFUSED
# once PLACE left a job waiting: "refused.PLACE=NOW", beside the other
# places' marks still inside their hour; older marks are dropped.
rescue_skip() {
  printf '%s\n' "$1" | tr ' ' '\n' | awk -v p="$2" -v now="$3" '
    index($0, "refused.") == 1 {
      split(substr($0, 9), kv, "=")
      if (kv[1] != p && now - kv[2] < 3600) out = out (out == "" ? "" : " ") $0
    }
    END { print out (out == "" ? "" : " ") "refused." p "=" now }'
}

# rescue_words PLACE REASON: the one calm line the drain writes when it
# starts a run again.
rescue_words() {
  case "$2" in
    offline) echo "Your machine went offline while this build waited for it, so it was started again to find another place." ;;
    *) echo "$(place_name "$1") left this build waiting past your wait limit, so it was started again elsewhere, and $(place_name "$1") is passed over for an hour." ;;
  esac
}
